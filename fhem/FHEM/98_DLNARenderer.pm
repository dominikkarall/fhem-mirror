############################################################################
# 2016-05-04, v2.0.0 BETA4, dominik.karall@gmail.com $
#
# v2.0.0 BEAT4 - 201605XX
# - CHANGE: change state to offline/playing/stopped/paused/online
# - CHANGE: play is NOT setting AVTransport any more
# - FEATURE: support pauseToggle
#
# v2.0.0 BETA3 - 20160504
# - BUGFIX: XML parsing error "NOT_IMPLEMENTED"
# - CHANGE: change readings to lowcaseUppercase format
# - FEATURE: support pause
# - FEATURE: support seek REL_TIME
# - FEATURE: support next/prev
#
# v2.0.0 BETA2 - 20160403
# - FEATURE: support events from DLNA devices
# - FEATURE: support caskeid group definitions
#                set <name> saveGroupAs Bad
#                set <name> loadGroup Bad
# - FEATURE: support caskeid stereo mode
#                set <name> stereo MUNET1 MUNET2 MunetStereoPaar
#                set <name> standalone
# - CHANGE: use UPnP::ControlPoint from FHEM library
# - BUGFIX: fix presence status
#
# v2.0.0 BETA1 - 20160321
# - FEATURE: autodiscover and autocreate DLNA devices
#       just use "define dlnadevices DLNARenderer" and wait 2 minutes
# - FEATURE: support Caskeid (e.g. MUNET devices) with following commands
#                set <name> playEverywhere
#                set <name> stopPlayEverywhere
#                set <name> addUnit <UNIT>
#                set <name> removeUnit <UNIT>
#                set <name> enableBTCaskeid
#                set <name> disableBTCaskeid
# - FEATURE: display multiroom speakers in multiRoomUnits reading
# - FEATURE: automatically set alias for friendlyname
# - FEATURE: automatically set webCmd volume
# - FEATURE: automatically set devStateIcon audio icons
# - FEATURE: ignoreUDNs attribute in main
# - FEATURE: scanInterval attribute in main
#
# DLNA Module to play given URLs on a DLNA Renderer
# and control their volume. Just define
#    define dlnadevices DLNARenderer
# and look for devices in Unsorted section after 2 minutes.
#
# TODO
# - 500 Can't connect to 192.168.0.23:8080 at FHEM/lib/UPnP/ControlPoint.pm line 847
# - handle sockets via main event loop
# - FIX Loading device description failed
# - redesign multiroom functionality (virtual devices?)
# - SWR3 metadata is handled wrong by player
# - retrieve stereomode (GetMultiChannel...) every 5 minutes
# - add socket to mainloop with separate hash
# - map TransportState to state (online, offline, playing, stopped, ...)
# - use eval for all controlProxy functions to prevent crashes
# - support channels (radio stations) with attributes
# - support relative volume (+/-10)
# - use bulk update for readings
# - support multiprocess and InternalTimer for ControlPoint
# - support SetExtensions
# - support relative volume for all multiroom devices (multiRoomVolume)
# - implement speak functions
# - check Standby -> Online signal
# - remove attributes (scanInterval, ignoreUDNs, multiRoomGroups) from play devices
#
############################################################################

package main;

use strict;
use warnings;

use Blocking;

use HTML::Entities;
use XML::Simple;
use Data::Dumper;
use Data::UUID;

#get UPnP::ControlPoint loaded properly
my $gPath = '';
BEGIN {
	$gPath = substr($0, 0, rindex($0, '/'));
}
if (lc(substr($0, -7)) eq 'fhem.pl') { 
	$gPath = $attr{global}{modpath}.'/FHEM'; 
}
use lib ($gPath.'/lib', $gPath.'/FHEM/lib', './FHEM/lib', './lib', './FHEM', './', '/usr/local/FHEM/share/fhem/FHEM/lib');

use UPnP::ControlPoint;

###################################
sub DLNARenderer_Initialize($) {
  my ($hash) = @_;

  $hash->{SetFn}     = "DLNARenderer_Set";
  $hash->{DefFn}     = "DLNARenderer_Define";
  $hash->{UndefFn}   = "DLNARenderer_Undef";
  $hash->{AttrFn}    = "DLNARenderer_Attribute";
  $hash->{AttrList}  = "ignoreUDNs scanInterval multiRoomGroups ".$readingFnAttributes;
}

sub DLNARenderer_Attribute {
  my ($mode, $devName, $attrName, $attrValue) = @_;
  #ignoreUDNs, scanInterval, multiRoomGroups
  
  if($mode eq "set") {
    if($attrName eq "scanInterval") {
      if($attrValue > 86400) {
        return "DLNARenderer: Max scan intervall is 24 hours (86400s).";
      }
    }
  } elsif($mode eq "del") {
    
  }
  
  return undef;
}

sub DLNARenderer_handleControlpoint {
  my ($hash) = @_;
  
  eval {
    my $cp = $hash->{helper}{controlpoint};
    my @sockets = $cp->sockets();
    my $select = IO::Select->new(@sockets);
    my @sock = $select->can_read(1);
    foreach my $s (@sock) {
      $cp->handleOnce($s);
    }
  };
  my $error = $@;
  
  if($error) {
    #setup a new controlpoint on error
    #undef($hash->{helper}{controlpoint});
    Log3 $hash, 3, "DLNARenderer: Create new controlpoint due to error, $error";
    #$hash->{helper}{controlpoint} = DLNARenderer_setupControlpoint($hash);
  }
  
  InternalTimer(gettimeofday() + 1, 'DLNARenderer_handleControlpoint', $hash, 0);
  
  return undef;
}

sub DLNARenderer_setupControlpoint {
  my ($hash) = @_;
  my %empty = ();
  my $error;
  my $cp;
  
  do {
    eval {
      $cp = UPnP::ControlPoint->new(SearchPort => 0, SubscriptionPort => 0, MaxWait => 30, UsedOnlyIP => \%empty, IgnoreIP => \%empty);
    };
    $error = $@;
  } while($error);
  
  return $cp;
}

sub DLNARenderer_doDlnaSearch {
  my ($hash) = @_;

  #research every 30 minutes
  InternalTimer(gettimeofday() + 1800, 'DLNARenderer_doDlnaSearch', $hash, 0);

  eval {
    $hash->{helper}{controlpoint}->searchByType('urn:schemas-upnp-org:device:MediaRenderer:1', sub { DLNARenderer_discoverCallback($hash, @_); });
  };
  if($@) {
    Log3 $hash, 2, "DLNARenderer: Search failed with error $@";
  }
  return undef;
}

sub DLNARenderer_discoverCallback {
  my ($hash, $search, $device, $action) = @_;
  
  Log3 $hash, 4, "DLNARenderer: $action, ".$device->friendlyName();

  if($action eq "deviceAdded") {
    DLNARenderer_addedDevice($hash, $device);
  } elsif($action eq "deviceRemoved") {
    DLNARenderer_removedDevice($hash, $device);
  }
  return undef;
}

sub DLNARenderer_subscriptionCallback {
  my ($hash, $service, %properties) = @_;
  
  Log3 $hash, 4, "DLNARenderer: Received event: ".Dumper(%properties);
  
  foreach my $property (keys %properties) {
    
    $properties{$property} = decode_entities($properties{$property});
    
    my $xml;
    eval {
      if($properties{$property} =~ /xml/) {
        $xml = XMLin($properties{$property}, KeepRoot => 1, ForceArray => [qw(Volume Mute Loudness VolumeDB group)], KeyAttr => []);
      } else {
        $xml = $properties{$property};
      }
    };
    
    if($@) {
      Log3 $hash, 2, "DLNARenderer: XML formatting error: ".$@.", ".$properties{$property};
      next;
    }
    
    DLNARenderer_processEventXml($hash, $property, $xml);
  }
  
  return undef;
}

sub DLNARenderer_updateReadingByEvent {
  my ($hash, $readingName, $xmlEvent) = @_;
  
  my $currVal = ReadingsVal($hash->{NAME}, $readingName, "");
  
  if($xmlEvent) {
    Log3 $hash, 4, "DLNARenderer: Update reading $readingName with ".$xmlEvent->{val};
    my $val = $xmlEvent->{val};
    $val = "" if(ref $val eq ref {});
    if($val ne $currVal) {
      readingsSingleUpdate($hash, $readingName, $val, 1);
    }
  } else {
    #reset values only if the value itself is ""
    #readingsSingleUpdate($hash, $readingName, "", 1);
  }
  
  return undef;
}

sub DLNARenderer_updateVolumeByEvent {
  my ($hash, $readingName, $volume) = @_;
  my $balance = 0;
  my $balanceSupport = 0;
  
  foreach my $vol (@{$volume}) {
    my $channel = $vol->{Channel} ? $vol->{Channel} : $vol->{channel};
    if($channel) {
      if($channel eq "Master") {
        DLNARenderer_updateReadingByEvent($hash, $readingName, $vol);
      } elsif($channel eq "LF") {
        $balance -= $vol->{val};
        $balanceSupport = 1;
      } elsif($channel eq "RF") {
        $balance += $vol->{val};
        $balanceSupport = 1;
      }
    } else {
      DLNARenderer_updateReadingByEvent($hash, $readingName, $vol);
    }
  }
  
  if($readingName eq "volume" && $balanceSupport == 1) {
    readingsSingleUpdate($hash, "balance", $balance, 1);
  }
  
  return undef;
}

sub DLNARenderer_updateMetaData {
  my ($hash, $prefix, $metaData) = @_;
  my $metaDataAvailable = 0;

  $metaDataAvailable = 1 if(defined($metaData) && $metaData->{val} && $metaData->{val} ne "");
  
  if($metaDataAvailable) {
    my $xml;
    if($metaData->{val} eq "NOT_IMPLEMENTED") {
      readingsSingleUpdate($hash, $prefix."Title", "", 1);
      readingsSingleUpdate($hash, $prefix."Artist", "", 1);
      readingsSingleUpdate($hash, $prefix."Album", "", 1);
      readingsSingleUpdate($hash, $prefix."AlbumArtist", "", 1);
      readingsSingleUpdate($hash, $prefix."AlbumArtURI", "", 1);
      readingsSingleUpdate($hash, $prefix."OriginalTrackNumber", "", 1);
      readingsSingleUpdate($hash, $prefix."Duration", "", 1);
    } else {
      eval {
        $xml = XMLin($metaData->{val}, KeepRoot => 1, ForceArray => [], KeyAttr => []);
        Log3 $hash, 4, "DLNARenderer: MetaData: ".Dumper($xml);
      };

      if(!$@) {
        DLNARenderer_updateMetaDataItemPart($hash, $prefix."Title", $xml->{"DIDL-Lite"}{item}{"dc:title"});
        DLNARenderer_updateMetaDataItemPart($hash, $prefix."Artist", $xml->{"DIDL-Lite"}{item}{"dc:creator"});
        DLNARenderer_updateMetaDataItemPart($hash, $prefix."Album", $xml->{"DIDL-Lite"}{item}{"upnp:album"});
        DLNARenderer_updateMetaDataItemPart($hash, $prefix."AlbumArtist", $xml->{"DIDL-Lite"}{item}{"r:albumArtist"});
        if($xml->{"DIDL-Lite"}{item}{"upnp:albumArtURI"}) {
          DLNARenderer_updateMetaDataItemPart($hash, $prefix."AlbumArtURI", $xml->{"DIDL-Lite"}{item}{"upnp:albumArtURI"});
        } else {
          readingsSingleUpdate($hash, $prefix."AlbumArtURI", "", 1);
        }
        DLNARenderer_updateMetaDataItemPart($hash, $prefix."OriginalTrackNumber", $xml->{"DIDL-Lite"}{item}{"upnp:originalTrackNumber"});
        if($xml->{"DIDL-Lite"}{item}{res}) {
          DLNARenderer_updateMetaDataItemPart($hash, $prefix."Duration", $xml->{"DIDL-Lite"}{item}{res}{duration});
        } else {
          readingsSingleUpdate($hash, $prefix."Duration", "", 1);
        }
      } else {
        Log3 $hash, 1, "DLNARenderer: XML parsing error: ".$@;
      }
    }
  } else {
    #no metadata available -> reset
    #reset only if empty metadata has been received
    #readingsSingleUpdate($hash, $prefix."Title", "", 1);
    #readingsSingleUpdate($hash, $prefix."Artist", "", 1);
    #readingsSingleUpdate($hash, $prefix."Album", "", 1);
    #readingsSingleUpdate($hash, $prefix."AlbumArtist", "", 1);
    #readingsSingleUpdate($hash, $prefix."AlbumArtURI", "", 1);
    #readingsSingleUpdate($hash, $prefix."OriginalTrackNumber", "", 1);
    #readingsSingleUpdate($hash, $prefix."Duration", "", 1);
  }

  return undef;
}

sub DLNARenderer_updateMetaDataItemPart {
  my ($hash, $readingName, $item) = @_;

  my $currVal = ReadingsVal($hash->{NAME}, $readingName, "");
  if($item) {
    $item = "" if(ref $item eq ref {});
    if($currVal ne $item) {
      readingsSingleUpdate($hash, $readingName, $item, 1);
    }
  } else {
    #update only if empty received
    #readingsSingleUpdate($hash, $readingName, "", 1);
  }
  return undef;
}

sub DLNARenderer_processEventXml {
  my ($hash, $property, $xml) = @_;

  Log3 $hash, 4, "DLNARenderer: ".Dumper($xml);
  
  if($property eq "LastChange") {
    if($xml->{Event}) {
      if($xml->{Event}{xmlns} eq "urn:schemas-upnp-org:metadata-1-0/AVT/") {
        #process AV Transport
        my $e = $xml->{Event}{InstanceID};
        #DLNARenderer_updateReadingByEvent($hash, "NumberOfTracks", $e->{NumberOfTracks});
        DLNARenderer_updateReadingByEvent($hash, "transportState", $e->{TransportState});
        if($e->{TransportState} eq "PAUSED_PLAYBACK") {
            readingsSingleUpdate($hash, "state", "paused", 1);
        } elsif($e->{TransportState} eq "PLAYING") {
            readingsSingleUpdate($hash, "state", "playing", 1);
        } elsif($e->{TransportState} eq "TRANSITIONING") {
            readingsSingleUpdate($hash, "state", "buffering", 1);
        } elsif($e->{TransportState} eq "STOPPED") {
            readingsSingleUpdate($hash, "state", "stopped", 1);
        } elsif($e->{TransportState} eq "NO_MEDIA_PRESENT") {
            readingsSingleUpdate($hash, "state", "online", 1);
        }
        DLNARenderer_updateReadingByEvent($hash, "transportStatus", $e->{TransportStatus});
        #DLNARenderer_updateReadingByEvent($hash, "TransportPlaySpeed", $e->{TransportPlaySpeed});
        #DLNARenderer_updateReadingByEvent($hash, "PlaybackStorageMedium", $e->{PlaybackStorageMedium});
        #DLNARenderer_updateReadingByEvent($hash, "RecordStorageMedium", $e->{RecordStorageMedium});
        #DLNARenderer_updateReadingByEvent($hash, "RecordMediumWriteStatus", $e->{RecordMediumWriteStatus});
        #DLNARenderer_updateReadingByEvent($hash, "CurrentRecordQualityMode", $e->{CurrentRecordQualityMode});
        #DLNARenderer_updateReadingByEvent($hash, "PossibleRecordQualityMode", $e->{PossibleRecordQualityMode});
        DLNARenderer_updateReadingByEvent($hash, "currentTrackURI", $e->{CurrentTrackURI});
        #DLNARenderer_updateReadingByEvent($hash, "AVTransportURI", $e->{AVTransportURI});
        DLNARenderer_updateReadingByEvent($hash, "nextAVTransportURI", $e->{NextAVTransportURI});
        #DLNARenderer_updateReadingByEvent($hash, "RelativeTimePosition", $e->{RelativeTimePosition});
        #DLNARenderer_updateReadingByEvent($hash, "AbsoluteTimePosition", $e->{AbsoluteTimePosition});
        #DLNARenderer_updateReadingByEvent($hash, "RelativeCounterPosition", $e->{RelativeCounterPosition});
        #DLNARenderer_updateReadingByEvent($hash, "AbsoluteCounterPosition", $e->{AbsoluteCounterPosition});
        #DLNARenderer_updateReadingByEvent($hash, "CurrentTrack", $e->{CurrentTrack});
        #DLNARenderer_updateReadingByEvent($hash, "CurrentMediaDuration", $e->{CurrentMediaDuration});
        #DLNARenderer_updateReadingByEvent($hash, "CurrentTrackDuration", $e->{CurrentTrackDuration});
        #DLNARenderer_updateReadingByEvent($hash, "CurrentPlayMode", $e->{CurrentPlayMode});
        #handle metadata
        #DLNARenderer_updateReadingByEvent($hash, "AVTransportURIMetaData", $e->{AVTransportURIMetaData});
        #DLNARenderer_updateMetaData($hash, "current", $e->{AVTransportURIMetaData});
        #DLNARenderer_updateReadingByEvent($hash, "NextAVTransportURIMetaData", $e->{NextAVTransportURIMetaData});
        DLNARenderer_updateMetaData($hash, "next", $e->{NextAVTransportURIMetaData});
        #use only CurrentTrackMetaData instead of AVTransportURIMetaData
        #DLNARenderer_updateReadingByEvent($hash, "CurrentTrackMetaData", $e->{CurrentTrackMetaData});
        DLNARenderer_updateMetaData($hash, "current", $e->{CurrentTrackMetaData});
      } elsif ($xml->{Event}{xmlns} eq "urn:schemas-upnp-org:metadata-1-0/RCS/") {
        #process RenderingControl
        my $e = $xml->{Event}{InstanceID};
        DLNARenderer_updateVolumeByEvent($hash, "mute", $e->{Mute});
        DLNARenderer_updateVolumeByEvent($hash, "volume", $e->{Volume});
      } elsif ($xml->{Event}{xmlns} eq "FIXME SpeakerManagement") {
        #process SpeakerManagement
      }
    }
  } elsif($property eq "Groups") {
    #handle BTCaskeid
    my $btCaskeidState = 0;
    foreach my $group (@{$xml->{groups}{group}}) {
      #"4DAA44C0-8291-11E3-BAA7-0800200C9A66", "Bluetooth"
      if($group->{id} eq "4DAA44C0-8291-11E3-BAA7-0800200C9A66") {
        $btCaskeidState = 1;
      }
    }
    #TODO update only if changed
    readingsSingleUpdate($hash, "btCaskeid", $btCaskeidState, 1);
  } elsif($property eq "SessionID") {
    #TODO search for other speakers with same sessionId and add them to multiRoomUnits
    readingsSingleUpdate($hash, "sessionId", $xml, 1);
  }
  
  return undef;
}

sub DLNARenderer_removedDevice($$) {
  my ($hash, $device) = @_;
  my $deviceHash = DLNARenderer_getHashByUDN($hash, $device->UDN());
  
  readingsSingleUpdate($deviceHash, "presence", "offline", 1);
  readingsSingleUpdate($deviceHash, "state", "offline", 1);
}

sub DLNARenderer_renewSubscriptions {
  my ($hash) = @_;
  my $dev = $hash->{helper}{device};
  
  InternalTimer(gettimeofday() + 200, 'DLNARenderer_renewSubscriptions', $hash, 0);
  
  return undef if(!defined($dev));
  
  #register callbacks
  #urn:upnp-org:serviceId:AVTransport
  eval {
    if(defined($hash->{helper}{avTransportSubscription})) {
      $hash->{helper}{avTransportSubscription}->renew();
    }
  };
  
  #urn:upnp-org:serviceId:RenderingControl
  eval {
    if(defined($hash->{helper}{renderingControlSubscription})) {
      $hash->{helper}{renderingControlSubscription}->renew();
    }
  };
  
  #urn:pure-com:serviceId:SpeakerManagement
  eval {
    if(defined($hash->{helper}{speakerManagementSubscription})) {
      $hash->{helper}{speakerManagementSubscription}->renew();
    }
  };
  
  return undef;
}

sub DLNARenderer_addedDevice {
  my ($hash, $dev) = @_;
  
  my $udn = $dev->UDN();

  #TODO check for BOSE UDN

  #ignoreUDNs
  return undef if(AttrVal($hash->{NAME}, "ignoreUDNs", "") =~ /$udn/);
    
  my $foundDevice = 0;
  my @allDLNARenderers = DLNARenderer_getAllDLNARenderers($hash);
  foreach my $DLNARendererHash (@allDLNARenderers) {
    if($DLNARendererHash->{UDN} eq $dev->UDN()) {
      $foundDevice = 1;
    }
  }
    
  if(!$foundDevice) {
    my $uniqueDeviceName = "DLNA_".substr($dev->UDN(),29,12);
    CommandDefine(undef, "$uniqueDeviceName DLNARenderer ".$dev->UDN());
    CommandAttr(undef,"$uniqueDeviceName alias ".$dev->friendlyName());
    CommandAttr(undef,"$uniqueDeviceName devStateIcon on:audio_volume_high off:audio_volume_mute");
    CommandAttr(undef,"$uniqueDeviceName webCmd volume");
    Log3 $hash, 3, "DLNARenderer: Created device $uniqueDeviceName for ".$dev->friendlyName();
    
    #update list
    @allDLNARenderers = DLNARenderer_getAllDLNARenderers($hash);
  }
  
  foreach my $DLNARendererHash (@allDLNARenderers) {
    if($DLNARendererHash->{UDN} eq $dev->UDN()) {
      #device found, update data
      $DLNARendererHash->{helper}{device} = $dev;
      
      #update device information (FIXME only on change)
      readingsSingleUpdate($DLNARendererHash, "friendlyName", $dev->friendlyName(), 1);
      readingsSingleUpdate($DLNARendererHash, "manufacturer", $dev->manufacturer(), 1);
      readingsSingleUpdate($DLNARendererHash, "modelDescription", $dev->modelDescription(), 1);
      readingsSingleUpdate($DLNARendererHash, "modelName", $dev->modelName(), 1);
      readingsSingleUpdate($DLNARendererHash, "modelNumber", $dev->modelNumber(), 1);
      readingsSingleUpdate($DLNARendererHash, "modelURL", $dev->modelURL(), 1);
      readingsSingleUpdate($DLNARendererHash, "manufacturerURL", $dev->manufacturerURL(), 1);
      readingsSingleUpdate($DLNARendererHash, "presentationURL", $dev->presentationURL(), 1);
      readingsSingleUpdate($DLNARendererHash, "manufacturer", $dev->manufacturer(), 1);
      
      #register callbacks
      #urn:upnp-org:serviceId:AVTransport
      if($dev->getService("urn:upnp-org:serviceId:AVTransport")) {
        $DLNARendererHash->{helper}{avTransportSubscription} = $dev->getService("urn:upnp-org:serviceId:AVTransport")->subscribe(sub { DLNARenderer_subscriptionCallback($DLNARendererHash, @_); });
      }
      #urn:upnp-org:serviceId:RenderingControl
      if($dev->getService("urn:upnp-org:serviceId:RenderingControl")) {
        $DLNARendererHash->{helper}{renderingControlSubscription} = $dev->getService("urn:upnp-org:serviceId:RenderingControl")->subscribe(sub { DLNARenderer_subscriptionCallback($DLNARendererHash, @_); });
      }
      #urn:pure-com:serviceId:SpeakerManagement
      if($dev->getService("urn:pure-com:serviceId:SpeakerManagement")) {
        $DLNARendererHash->{helper}{speakerManagementSubscription} = $dev->getService("urn:pure-com:serviceId:SpeakerManagement")->subscribe(sub { DLNARenderer_subscriptionCallback($DLNARendererHash, @_); });
      }
      
      #set render_service
      $DLNARendererHash->{helper}{render_service} = $dev->getService("urn:upnp-org:serviceId:RenderingControl");;
      readingsSingleUpdate($DLNARendererHash,"presence","online",1);
      if(ReadingsVal($DLNARendererHash->{NAME}, "state", "") eq "offline") {
        readingsSingleUpdate($DLNARendererHash,"state","online",1);
      }
      
      #check caskeid
      if($dev->getService('urn:pure-com:serviceId:SessionManagement')) {
        $DLNARendererHash->{helper}{caskeid} = 1;
        readingsSingleUpdate($DLNARendererHash,"multiRoomSupport","1",1);
      } else {
        readingsSingleUpdate($DLNARendererHash,"multiRoomSupport","0",1);
      }
      
      #update list of caskeid clients
      my @caskeidClients = DLNARenderer_getAllDLNARenderersWithCaskeid($hash);
      $DLNARendererHash->{helper}{caskeidClients} = "";
      foreach my $client (@caskeidClients) {
        #do not add myself
        if($client->{UDN} ne $DLNARendererHash->{UDN}) {
          $DLNARendererHash->{helper}{caskeidClients} .= ",".ReadingsVal($client->{NAME}, "friendlyName", "");
        }
      }
      $DLNARendererHash->{helper}{caskeidClients} = substr($DLNARendererHash->{helper}{caskeidClients}, 1) if($DLNARendererHash->{helper}{caskeidClients} ne "");
    }
  }
  
  return undef;
}

sub DLNARenderer_getMainDLNARenderer($) {
  my ($hash) = @_;
    
  foreach my $fhem_dev (sort keys %main::defs) { 
    return $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'DLNARenderer' && $main::defs{$fhem_dev}{UDN} eq "0");
  }
		
  return undef;
}

sub DLNARenderer_getHashByUDN($$) {
  my ($hash, $udn) = @_;
  
  foreach my $fhem_dev (sort keys %main::defs) { 
    return $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'DLNARenderer' && $main::defs{$fhem_dev}{UDN} eq $udn);
  }
		
  return undef;
}

sub DLNARenderer_getAllDLNARenderers($) {
  my ($hash) = @_;
  my @DLNARenderers = ();
    
  foreach my $fhem_dev (sort keys %main::defs) { 
    push @DLNARenderers, $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'DLNARenderer' && $main::defs{$fhem_dev}{UDN} ne "0");
  }
		
  return @DLNARenderers;
}

sub DLNARenderer_getAllDLNARenderersWithCaskeid($) {
  my ($hash) = @_;
  my @caskeidClients = ();
  
  my @DLNARenderers = DLNARenderer_getAllDLNARenderers($hash);
  foreach my $DLNARenderer (@DLNARenderers) {
    push @caskeidClients, $DLNARenderer if($DLNARenderer->{helper}{caskeid});
  }
  
  return @caskeidClients;
}

sub DLNARenderer_updateVolume($) {
  my ($hash) = @_;
  my $render_service = $hash->{helper}{render_service};
  
  #get current volume
  if ($render_service) {
    my $currVolume = $render_service->controlProxy()->GetVolume(0, "Master")->getValue("CurrentVolume");
    if (defined($hash->{READINGS}{volume}) and $hash->{READINGS}{volume}{VAL} ne $currVolume) {
      readingsSingleUpdate($hash, "volume", $currVolume, 1);
    }
  }
  
  return undef;
}

###################################
sub DLNARenderer_setAVTransportBlocking($) {
  my ($string) = @_;
  my ($name, $streamURI) = split("\\|", $string);
  my $hash = $main::defs{$name};
  my $return = "$name|$streamURI";
  
  my $avtrans_service = $hash->{helper}{device}->getService('urn:upnp-org:serviceId:AVTransport');
  my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
  $avtrans_ctrlproxy->SetAVTransportURI(0, $streamURI, "");

  return $return;
}

sub DLNARenderer_finishedSetAVTransportBlocking($) {
  my ($string) = @_;
  my @params = split("\\|", $string);
  my $name = $params[0];
  my $hash = $defs{$name};
  
  readingsSingleUpdate($hash,"stream",$params[1],1);
  
  DLNARenderer_play($hash);
  
  return undef;
}
###################################
sub DLNARenderer_play($) {
  my ($hash) = @_;
  
  #start play
  if($hash->{helper}{caskeid}) {
    DLNARenderer_syncPlay($hash, $hash->{helper}{device});
  } else {
    my $avtrans_service = $hash->{helper}{device}->getService('urn:upnp-org:serviceId:AVTransport');
    my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
    $avtrans_ctrlproxy->Play(0, 1);
  }
  
  return undef;
}

sub DLNARenderer_syncPlay($$) {
  my ($hash, $dev) = @_;
  my $avtrans_service = $dev->getService('urn:upnp-org:serviceId:AVTransport');
  my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
  $avtrans_ctrlproxy->SyncPlay(0, 1, "REL_TIME", "", "", "", "DeviceClockId");
}

sub DLNARenderer_enableBTCaskeid {
  my ($hash, $dev) = @_;
  DLNARenderer_addUnitToGroup($hash, $dev, "4DAA44C0-8291-11E3-BAA7-0800200C9A66", "Bluetooth");
}

sub DLNARenderer_disableBTCaskeid {
  my ($hash, $dev) = @_;
  DLNARenderer_removeUnitFromGroup($hash, $dev, "4DAA44C0-8291-11E3-BAA7-0800200C9A66");
}

### DLNA SpeakerManagement ###
sub DLNARenderer_addUnitToGroup {
  my ($hash, $dev, $unit, $name) = @_;
  my $service = $dev->getService('urn:pure-com:serviceId:SpeakerManagement')->controlProxy();
  $service->AddToGroup($unit, $name, "");
}

sub DLNARenderer_removeUnitFromGroup {
  my ($hash, $dev, $unit) = @_;
  my $service = $dev->getService('urn:pure-com:serviceId:SpeakerManagement')->controlProxy();
  $service->RemoveFromGroup($unit);
  return undef;
}

sub DLNARenderer_setStereoMode {
  my ($hash, $leftSpeaker, $rightSpeaker, $name) = @_;
  
  my @multiRoomDevices = DLNARenderer_getAllDLNARenderersWithCaskeid($hash);
  my $uuid = DLNARenderer_createUuid($hash);
  
  DLNARenderer_destroyCurrentSession($hash, $hash->{helper}{device});
  
  foreach my $device (@multiRoomDevices) {
    if(ReadingsVal($device->{NAME}, "friendlyName", "") eq $leftSpeaker) {
      DLNARenderer_setMultiChannelSpeaker($device, "left", $uuid, $name);
    } elsif(ReadingsVal($device->{NAME}, "friendlyName", "") eq $rightSpeaker) {
      DLNARenderer_setMultiChannelSpeaker($device, "right", $uuid, $name);
    }
  }
  
  readingsSingleUpdate($hash, "stereoDevices", "R:$rightSpeaker,L:$leftSpeaker", 1);
  
  return undef;
}

sub DLNARenderer_setStandaloneMode {
  my ($hash) = @_;
  my @multiRoomDevices = DLNARenderer_getAllDLNARenderersWithCaskeid($hash);
  my @stereoDevices = split(",", ReadingsVal($hash->{NAME}, "stereoDevices", ""));
  my $rightSpeaker;
  my $leftSpeaker;
  
  foreach my $device (@stereoDevices) {
    if($device =~ /^R:([a-zA-Z0-9äöüßÄÜÖ_]+)/) {
      $rightSpeaker = $1;
    } elsif($device =~ /^L:([a-zA-Z0-9äöüßÄÜÖ_]+)/) {
      $leftSpeaker = $1;
    }
  }
  
  foreach my $device (@multiRoomDevices) {
    if(ReadingsVal($device->{NAME}, "friendlyName", "") eq $leftSpeaker or
       ReadingsVal($device->{NAME}, "friendlyName", "") eq $rightSpeaker) {
      DLNARenderer_setMultiChannelSpeaker($device, "standalone", "", "");
    }
  }
  
  readingsSingleUpdate($hash, "stereoDevices", "", 1);
  
  return undef;
}

sub DLNARenderer_createUuid {
  my ($hash) = @_;
  my $ug = Data::UUID->new();
  my $uuid = $ug->create();
  my $uuidStr = $ug->to_string($uuid);
  
  return $uuidStr;
}

sub DLNARenderer_setMultiChannelSpeaker {
  my ($hash, $mode, $uuid, $name) = @_;
  my $service = $hash->{helper}{device}->getService('urn:pure-com:serviceId:SpeakerManagement')->controlProxy();
  my $uuidStr;
  
  if($mode eq "standalone") {
    $service->SetMultiChannelSpeaker("STANDALONE", "", "", "STANDALONE_SPEAKER");
  } elsif($mode eq "left") {
    $service->SetMultiChannelSpeaker("STEREO", $uuid, $name, "LEFT_FRONT");
  } elsif($mode eq "right") {
    $service->SetMultiChannelSpeaker("STEREO", $uuid, $name, "RIGHT_FRONT");
  }
  
  return undef;  
}

### DLNA SessionManagement ###
sub DLNARenderer_addUnitToPlay {
  my ($hash, $dev, $unit) = @_;
  
  my $session = DLNARenderer_getSession($hash, $dev);
  
  if($session eq "") {
    $session = DLNARenderer_createSession($hash, $dev);
  }
  
  DLNARenderer_addUnitToSession($hash, $dev, $unit, $session);
}

sub DLNARenderer_removeUnitToPlay {
  my ($hash, $dev, $unit) = @_;
  
  my $session = DLNARenderer_getSession($hash, $dev);
  
  if($session ne "") {
    DLNARenderer_removeUnitFromSession($hash, $dev, $unit, $session);
  }
}

sub DLNARenderer_destroyCurrentSession {
  my ($hash, $dev) = @_;
  
  my $session = DLNARenderer_getSession($hash, $dev);
  
  if($session ne "") {
    DLNARenderer_destroySession($hash, $dev, $session);
  }
}

sub DLNARenderer_createSession {
  my ($hash, $dev) = @_;
  my $conn_service = $dev->getService('urn:pure-com:serviceId:SessionManagement')->controlProxy();
  return $conn_service->CreateSession("FHEM Session")->getValue("SessionID");
}

sub DLNARenderer_getSession {
  my ($hash, $dev) = @_;
  my $conn_service = $dev->getService('urn:pure-com:serviceId:SessionManagement')->controlProxy();
  return $conn_service->GetSession()->getValue("SessionID");
}

sub DLNARenderer_addUnitToSession {
  my ($hash, $dev, $uuid, $session) = @_;
  my $conn_service = $dev->getService('urn:pure-com:serviceId:SessionManagement')->controlProxy();
  $conn_service->AddUnitToSession($session, $uuid);
}

sub DLNARenderer_removeUnitFromSession {
  my ($hash, $dev, $uuid, $session) = @_;
  my $conn_service = $dev->getService('urn:pure-com:serviceId:SessionManagement')->controlProxy();
  $conn_service->RemoveUnitFromSession($session, $uuid);
}

sub DLNARenderer_destroySession {
  my ($hash, $dev, $sessionId) = @_;
  my $conn_service = $dev->getService('urn:pure-com:serviceId:SessionManagement')->controlProxy();
  $conn_service->DestroySession($sessionId);
}

sub DLNARenderer_getGroupDefinition {
  #used for ... play Bad ...
  my ($hash, $groupName) = @_;
  my $currentGroupSettings = AttrVal($hash->{NAME}, "multiRoomGroups", "");
  
  #regex Bad[MUNET1,MUNET2],WZ[L:MUNET2,R:MUNET3],...
  while ($currentGroupSettings =~ /([a-zA-Z0-9äöüßÄÜÖ_]+)\[([a-zA-Z,0-9:äöüßÄÜÖ_]+)/g) {
    my $group = $1;
    my $groupMembers = $2;
    
    Log3 $hash, 4, "DLNARenderer: Groupdefinition $group => $groupMembers";
    
    if($group eq $groupName) {
      return $groupMembers;
    }
  }
  
  return undef;
}

sub DLNARenderer_saveGroupAs {
  my ($hash, $dev, $groupName) = @_;  
  my $currentGroupSettings = AttrVal($hash->{NAME}, "multiRoomGroups", "");
  $currentGroupSettings .= "," if($currentGroupSettings ne "");
  
  #session details
  my $currentSession = ReadingsVal($hash->{NAME}, "multiRoomUnits", "");
  #stereo mode
  my $stereoDevices = ReadingsVal($hash->{NAME}, "stereoDevices", "");
  return undef if($currentSession eq "" && $stereoDevices eq "");
  $stereoDevices .= "," if($stereoDevices ne "" && $currentSession ne "");
  
  my $groupDefinition = $currentGroupSettings.$groupName."[".$stereoDevices.$currentSession."]";
    
  #save current session as group
  CommandAttr(undef, "$hash->{NAME} multiRoomGroups $groupDefinition");
  
  return undef;
}

###################################
sub DLNARenderer_Define($$) {
  my ($hash, $def) = @_;
  my @param = split("[ \t][ \t]*", $def);
  
  #init caskeid clients for multiroom
  $hash->{helper}{caskeidClients} = "";
  $hash->{helper}{caskeid} = 0;
  
  if(@param < 3) {
    #main
    $hash->{UDN} = 0;
    Log3 $hash, 3, "DLNARenderer: DLNA Renderer v2.0.0 BETA3";
    $hash->{helper}{controlpoint} = DLNARenderer_setupControlpoint($hash);
    DLNARenderer_doDlnaSearch($hash);
    DLNARenderer_handleControlpoint($hash);
    readingsSingleUpdate($hash,"state","initialized",1);
    return undef;
  }
  
  #device specific
  my $name     = shift @param;
  my $type     = shift @param;
  my $udn      = shift @param;
  $hash->{UDN} = $udn;
  
  readingsSingleUpdate($hash,"presence","offline",1);
  readingsSingleUpdate($hash,"state","initialized",1);
  
  InternalTimer(gettimeofday() + 200, 'DLNARenderer_renewSubscriptions', $hash, 0);
  
  return undef;
}

###################################
sub DLNARenderer_Undef($) {
  my ($hash) = @_;
  
  RemoveInternalTimer($hash);
  return undef;
}
###################################
sub DLNARenderer_Set($@) {
  my ($hash, @param) = @_;
  my $dev = $hash->{helper}{device};
  my $render_service = $hash->{helper}{render_service};
  my $streamURI = "";
  
  # check parameters
  return "no set value specified" if(int(@param) < 1);
  my $ctrlParam = $param[1];
  
  if ($ctrlParam eq "?") {
    if($hash->{helper}{caskeid}) {
      return "Unknown argument, choose one of on:noArg off:noArg play:noArg stop:noArg stream volume:slider,0,1,100 ".
             "pause:noArg next:noArg previous:noArg seek ".
             "addUnit:".$hash->{helper}{caskeidClients}." ".
             "playEverywhere:noArg stopPlayEverywhere:noArg ".
             "removeUnit:".ReadingsVal($hash->{NAME}, "multiRoomUnits", "")." ".
             "enableBTCaskeid:noArg disableBTCaskeid:noArg saveGroupAs loadGroup ".
             "stereo standalone:noArg";
    } else {
      return "Unknown argument, choose one of on:noArg off:noArg play:noArg stop:noArg stream pause:noArg next:noArg previous:noArg seek volume:slider,0,1,100";
    }
  }
    
  # check device presence
  if (!defined($dev) or ReadingsVal($hash->{NAME}, "presence", "") eq "offline") {
    return "DLNARenderer: Currently searching for device...";
  }
  
  # set volume
  if($ctrlParam eq "volume"){
    if(!$render_service) {
      Log3 $hash, 3, "DLNARenderer: No volume control possible for this device";
      return undef;
    }
    return "DLNARenderer: Missing argument for volume." if (int(@param) < 3);
    $render_service->controlProxy()->SetVolume(0, "Master", $param[2]);
    readingsSingleUpdate($hash, "volume", $param[2], 1);
    return undef;
  }
  
  #pause
  if($ctrlParam eq "pause") {
    my $avtrans_service = $hash->{helper}{device}->getService('urn:upnp-org:serviceId:AVTransport');
    my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
    $avtrans_ctrlproxy->Pause(0);
    return undef;
  }
  
  #pauseToggle
  if($ctrlParam eq "pauseToggle") {
    if($hash->{READINGS}{state} eq "paused") {
        DLNARenderer_play($hash);
    } else {
        my $avtrans_service = $hash->{helper}{device}->getService('urn:upnp-org:serviceId:AVTransport');
        my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
        $avtrans_ctrlproxy->Pause(0);
    }
    return undef;
  }
  
  #play
  if($ctrlParam eq "play") {
    DLNARenderer_play($hash);
    return undef;
  }
  
  #next
  if($ctrlParam eq "next") {
    my $avtrans_service = $hash->{helper}{device}->getService('urn:upnp-org:serviceId:AVTransport');
    my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
    $avtrans_ctrlproxy->Next(0);
    return undef;
  }
  
  #previous
  if($ctrlParam eq "previous") {
    my $avtrans_service = $hash->{helper}{device}->getService('urn:upnp-org:serviceId:AVTransport');
    my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
    $avtrans_ctrlproxy->Previous(0);
    return undef;
  }
  
  #seek
  if($ctrlParam eq "seek") {
    my $avtrans_service = $hash->{helper}{device}->getService('urn:upnp-org:serviceId:AVTransport');
    my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
    $avtrans_ctrlproxy->Seek(0, "REL_TIME", $param[2]);
    return undef;
  }
  
  #TODO set multiRoomVolume
  if($ctrlParam eq "multiRoomVolume"){
    if(!$render_service) {
      Log3 $hash, 3, "DLNARenderer: No volume control possible for this device";
      return undef;
    }
    return "DLNARenderer: Missing argument for multiRoomVolume." if (int(@param) < 3);
    #handle volume for all devices in the current group
    #iterate through group and change volume relative to the current volume
    my $volumeDiff = ReadingsVal($hash->{NAME}, "volume", 0) - $param[2];
    #get grouped devices
      #set volume for each device
    #$render_service->controlProxy()->SetVolume(0, "Master", $param[2]);
    #readingsSingleUpdate($hash, "volume", $param[2], 1);
    return undef;
  }
  
  # stereo mode
  if($ctrlParam eq "stereo") {
    DLNARenderer_setStereoMode($hash, $param[2], $param[3], $param[4]);
    return undef;
  }
  
  # standalone mode
  if($ctrlParam eq "standalone") {
    DLNARenderer_setStandaloneMode($hash);
    return undef;
  }
  
  # playEverywhere
  if($ctrlParam eq "playEverywhere") {
    my $multiRoomUnits = "";
    my @caskeidClients = DLNARenderer_getAllDLNARenderersWithCaskeid($hash);
    foreach my $client (@caskeidClients) {
      if($client->{UDN} ne $hash->{UDN}) {
        DLNARenderer_addUnitToPlay($hash, $dev, substr($client->{UDN},5));
        $multiRoomUnits .= ",".ReadingsVal($client->{NAME}, "friendlyName", "");
      }
    }
    #remove first comma
    $multiRoomUnits = substr($multiRoomUnits, 1);
    readingsSingleUpdate($hash, "multiRoomUnits", $multiRoomUnits, 1);
    return undef;
  }
  
  # stopPlayEverywhere
  if($ctrlParam eq "stopPlayEverywhere") {
    DLNARenderer_destroyCurrentSession($hash, $dev);
    readingsSingleUpdate($hash, "multiRoomUnits", "", 1);
    return undef;
  }
  
  # addUnit
  if($ctrlParam eq "addUnit") {
    return DLNARenderer_addUnit($hash, $param[2]);
  }
  
  # removeUnit
  if($ctrlParam eq "removeUnit") {
    DLNARenderer_removeUnitToPlay($hash, $dev, $param[2]);
    my $multiRoomUnitsReading = "";
    my @multiRoomUnits = split(",", ReadingsVal($hash->{NAME}, "multiRoomUnits", ""));
    foreach my $unit (@multiRoomUnits) {
      $multiRoomUnitsReading .= ",".$unit if($unit ne $param[2]);
    }
    $multiRoomUnitsReading = substr($multiRoomUnitsReading, 1) if($multiRoomUnitsReading ne "");
    readingsSingleUpdate($hash, "multiRoomUnits", $multiRoomUnitsReading, 1);
    return undef;
  }
  
  # save group as
  if($ctrlParam eq "saveGroupAs") {
    DLNARenderer_saveGroupAs($hash, $dev, $param[2]);
    return undef;
  }
  
  # enableBTCaskeid
  if($ctrlParam eq "enableBTCaskeid") {
    DLNARenderer_enableBTCaskeid($hash, $dev);
    return undef;
  }
  
  # disableBTCaskeid
  if($ctrlParam eq "disableBTCaskeid") {
    DLNARenderer_disableBTCaskeid($hash, $dev);
    return undef;
  }
 
  # off/stop
  if($ctrlParam eq "off" || $ctrlParam eq "stop" ){
    my $avtrans_service = $hash->{helper}{device}->getService('urn:upnp-org:serviceId:AVTransport');
    my $avtrans_ctrlproxy = $avtrans_service->controlProxy();
    $avtrans_ctrlproxy->Stop(0);
    return undef;
  }
  
  # loadGroup
  if($ctrlParam eq "loadGroup") {
    return "DLNARenderer: loadGroup requires multiroom group as additional parameter." if(!defined($param[2]));
    my $groupName = $param[2];
    my $groupMembers = DLNARenderer_getGroupDefinition($hash, $groupName);
    return "DLNARenderer: Group $groupName not defined." if(!defined($groupMembers));
    
    #create new session and add each group member
    my @groupMembersArray = split(",", $groupMembers);
    DLNARenderer_destroyCurrentSession($hash, $dev);
    my $leftSpeaker;
    my $rightSpeaker;
    foreach my $member (@groupMembersArray) {
      if($member =~ /^R:([a-zA-Z0-9äöüßÄÜÖ_]+)/) {
        $rightSpeaker = $1;
      } elsif($member =~ /^L:([a-zA-Z0-9äöüßÄÜÖ_]+)/) {
        $leftSpeaker = $1;
      } else {
        DLNARenderer_addUnit($hash, $member);
      }
    }
    DLNARenderer_setStereoMode($hash, $leftSpeaker, $rightSpeaker, $groupName);
    
    return undef;
  }
  
  # on
  if($ctrlParam eq "on"){
    if (defined($hash->{READINGS}{stream})) {
      my $lastStream = $hash->{READINGS}{stream}{VAL};
      if ($lastStream) {
        $streamURI = $lastStream;
      }
    }
  }
  
  # set streamURI
  if (!$streamURI && $ctrlParam eq "stream") {
    $streamURI = $param[2];
  }

  BlockingCall('DLNARenderer_setAVTransportBlocking', $hash->{NAME}."|".$streamURI, 'DLNARenderer_finishedSetAVTransportBlocking');
  
  return undef;
}

sub DLNARenderer_addUnit {
  my ($hash, $unitName) = @_;
  
  my @caskeidClients = DLNARenderer_getAllDLNARenderersWithCaskeid($hash);
  foreach my $client (@caskeidClients) {
    if(ReadingsVal($client->{NAME}, "friendlyName", "") eq $unitName) {
      my @multiRoomUnits = split(",", ReadingsVal($hash->{NAME}, "multiRoomUnits", ""));
      foreach my $unit (@multiRoomUnits) {
        #skip if unit is already part of the session
        return undef if($unit eq $unitName);
      }
      #add unit to session
      DLNARenderer_addUnitToPlay($hash, $hash->{helper}{device}, substr($client->{UDN},5));
      my $currMultiRoomUnits = ReadingsVal($hash->{NAME}, "multiRoomUnits","");
      if($currMultiRoomUnits ne "") {
        readingsSingleUpdate($hash, "multiRoomUnits", $currMultiRoomUnits.",".$unitName, 1);
      } else {
        readingsSingleUpdate($hash, "multiRoomUnits", $unitName, 1);
      }
      return undef;
    }
  }
  return "DLNARenderer: No unit $unitName found.";
}

1;

=pod
=begin html

<a name="DLNARenderer"></a>
<h3>DLNARenderer</h3>
<ul>

  Define a DLNA client. A DLNA client can take an URL to play via <a href="#set">set</a>.
  
  <br><br>

  <a name="DLNARendererdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; DLNARenderer</code>
    <br><br>

    Example:
    <ul>
      <code>define dlnadevices DLNARenderer</code><br>
      After 2 minutes you can find all DLNA renderers in "Unsorted".<br/>
    </ul>
  </ul>
  <br>

  <a name="DLNARendererset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; stream &lt;value&gt</code><br>
    Set any URL to play.
  </ul>
  <ul>
    <code>set &lt;name&gt; &lt;volume&gt 0-100</code><br>
    Set volume of the device.
  </ul>
  <br>

</ul>

=end html
=cut
