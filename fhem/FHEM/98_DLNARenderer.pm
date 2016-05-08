############################################################################
# 2016-05-04, v2.0.0 BETA4, dominik.karall@gmail.com $
#
# v2.0.0 BEAT4 - 201605XX
# - CHANGE: change state to offline/playing/stopped/paused/online
# - CHANGE: removed on/off devstateicon on creation due to changed state values
# - CHANGE: play is NOT setting AVTransport any more
# - CHANGE: code cleanup
# - FEATURE: support pauseToggle
# - FEATURE: support SetExtensions (on-for-timer, off-for-timer, ...)
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
#TODO
# - use blocking call for all upnpCalls
# - handle sockets via main event loop
# - FIX Loading device description failed
# - redesign multiroom functionality (virtual devices?)
# - SWR3 metadata is handled wrong by player
# - retrieve stereomode (GetMultiChannel...) every 5 minutes
# - support channels (radio stations) with attributes
# - support relative volume (+/-10)
# - use bulk update for readings
# - support multiprocess and InternalTimer for ControlPoint
# - support relative volume for all multiroom devices (multiRoomVolume)
# - implement speak functions
# - remove attributes (scanInterval, ignoreUDNs, multiRoomGroups) from play devices
#
############################################################################

package main;

use strict;
use warnings;

use Blocking;
use SetExtensions;

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

sub DLNARenderer_Initialize($) {
  my ($hash) = @_;

  $hash->{SetFn}     = "DLNARenderer_Set";
  $hash->{DefFn}     = "DLNARenderer_Define";
  $hash->{ReadFn}    = "DLNARenderer_Read";
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

sub DLNARenderer_Define($$) {
  my ($hash, $def) = @_;
  my @param = split("[ \t][ \t]*", $def);
  
  #init caskeid clients for multiroom
  $hash->{helper}{caskeidClients} = "";
  $hash->{helper}{caskeid} = 0;
  
  if(@param < 3) {
    #main
    $hash->{UDN} = 0;
    Log3 $hash, 3, "DLNARenderer: DLNA Renderer v2.0.0 BETA4";
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
  readingsSingleUpdate($hash,"state","offline",1);
  
  InternalTimer(gettimeofday() + 200, 'DLNARenderer_renewSubscriptions', $hash, 0);
  
  return undef;
}

sub DLNARenderer_Undef($) {
  my ($hash) = @_;
  
  RemoveInternalTimer($hash);
  return undef;
}

sub DLNARenderer_Read($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $phash = $hash->{pash};
  my $cp = $phash->{helper}{controlpoint};
  
  eval {
    $cp->handleOnce($hash->{CD});
  };
  
  if($@) {
    Log3 $hash, 3, "DLNARenderer: handleOnce failed, $@";
  }
  
  my @sockets = $cp->sockets();
  #prüfen ob der socket schon in selectlist ist
  #wenn nicht, dann chash hinzufügen
  foreach my $s (@sockets) {
    my $socketExits = 0;
    foreach my $s2 (@{$phash->{helper}{sockets}}) {
      if($s eq $s2) {
        $socketExists = 1;
      }
    }
    
    if(!$socketExists) {
      #create chash and add to selectlist
      my $chash = DLNARenderer_newChash($hash, $s, {NAME => "DLNASocket"});
      push @{$phash->{helper}{sockets}}, $chash;
    }
    #prüfen ob der socket noch gebraucht wird
    #wenn nicht, dann aus selectlist löschen
  }
  
  return undef;
}

sub DLNARenderer_Set($@) {
  my ($hash, $name, @params) = @_;
  my $dev = $hash->{helper}{device};
  my $streamURI = "";
  
  # check parameters
  return "no set value specified" if(int(@params) < 1);
  my $ctrlParam = shift(@params);
  
  my $stdCommandList = "on:noArg off:noArg play:noArg stop:noArg stream pause:noArg pauseToggle:noArg next:noArg previous:noArg seek volume:slider,0,1,100";
  my $caskeidCommandList = "addUnit:".$hash->{helper}{caskeidClients}." ".
                           "removeUnit:".ReadingsVal($hash->{NAME}, "multiRoomUnits", "")." ".
                           "playEverywhere:noArg stopPlayEverywhere:noArg ".
                           "enableBTCaskeid:noArg disableBTCaskeid:noArg ".
                           "saveGroupAs loadGroup ".
                           "stereo standalone:noArg";
  
  # check device presence
  if ($ctrlParam ne "?" and (!defined($dev) or ReadingsVal($hash->{NAME}, "presence", "") eq "offline")) {
    return "DLNARenderer: Currently searching for device...";
  }
  
  if($ctrlParam eq "volume"){
    #volume
    return "DLNARenderer: Missing argument for volume." if (int(@params) < 1);
    DLNARenderer_upnpSetVolume($hash, $params[0]);
    readingsSingleUpdate($hash, "volume", $params[0], 1);
  } elsif($ctrlParam eq "pause") {
    #pause
    DLNARenderer_upnpPause($hash);
  } elsif($ctrlParam eq "pauseToggle") {
    #pauseToggle
    if($hash->{READINGS}{state} eq "paused") {
        DLNARenderer_play($hash);
    } else {
        DLNARenderer_upnpPause($hash);
    }
  } elsif($ctrlParam eq "play") {
    #play
    DLNARenderer_play($hash);
  } elsif($ctrlParam eq "next") {
    #next
    DLNARenderer_upnpNext($hash);
  } elsif($ctrlParam eq "previous") {
    #prev
    DLNARenderer_upnpPrevious($hash);
  } elsif($ctrlParam eq "seek") {
    #seek
    DLNARenderer_upnpSeek($hash, $params[0]);
  } elsif($ctrlParam eq "multiRoomVolume"){
    #multiroomvolume
    return "DLNARenderer: Missing argument for multiRoomVolume." if (int(@params) < 1);
    #handle volume for all devices in the current group
    #iterate through group and change volume relative to the current volume
    my $volumeDiff = ReadingsVal($hash->{NAME}, "volume", 0) - $params[0];
    #get grouped devices
      #set volume for each device
    #$render_service->controlProxy()->SetVolume(0, "Master", $params[0]);
    #readingsSingleUpdate($hash, "volume", $params[1], 1);
  } elsif($ctrlParam eq "stereo") {
    #stereo
    DLNARenderer_setStereoMode($hash, $params[0], $params[1], $params[2]);
  } elsif($ctrlParam eq "standalone") {
    #standalone
    DLNARenderer_setStandaloneMode($hash);
  } elsif($ctrlParam eq "playEverywhere") {
    #playEverywhere
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
  } elsif($ctrlParam eq "stopPlayEverywhere") {
    #stopPlayEverywhere
    DLNARenderer_destroyCurrentSession($hash, $dev);
    readingsSingleUpdate($hash, "multiRoomUnits", "", 1);
  } elsif($ctrlParam eq "addUnit") {
    #addUnit
    DLNARenderer_addUnit($hash, $params[0]);
  } elsif($ctrlParam eq "removeUnit") {
    #removeUnit
    DLNARenderer_removeUnitToPlay($hash, $dev, $params[0]);
    my $multiRoomUnitsReading = "";
    my @multiRoomUnits = split(",", ReadingsVal($hash->{NAME}, "multiRoomUnits", ""));
    foreach my $unit (@multiRoomUnits) {
      $multiRoomUnitsReading .= ",".$unit if($unit ne $params[0]);
    }
    $multiRoomUnitsReading = substr($multiRoomUnitsReading, 1) if($multiRoomUnitsReading ne "");
    readingsSingleUpdate($hash, "multiRoomUnits", $multiRoomUnitsReading, 1);
  } elsif($ctrlParam eq "saveGroupAs") {
    #saveGroupAs
    DLNARenderer_saveGroupAs($hash, $dev, $params[0]);
  } elsif($ctrlParam eq "enableBTCaskeid") {
    #enableBTCaskeid
    DLNARenderer_enableBTCaskeid($hash, $dev);
  } elsif($ctrlParam eq "disableBTCaskeid") {
    #disableBTCaskeid
    DLNARenderer_disableBTCaskeid($hash, $dev);
  } elsif($ctrlParam eq "off" || $ctrlParam eq "stop" ){
    #off/stop
    DLNARenderer_upnpStop($hash);
  } elsif($ctrlParam eq "loadGroup") {
    #loadGroup
    return "DLNARenderer: loadGroup requires multiroom group as additional parameter." if(!defined($params[0]));
    my $groupName = $params[0];
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
  } elsif($ctrlParam eq "on") {
    #on = play last stream
    if (defined($hash->{READINGS}{stream})) {
      my $lastStream = $hash->{READINGS}{stream}{VAL};
      if ($lastStream) {
        $streamURI = $lastStream;
        BlockingCall('DLNARenderer_setAVTransportURIBlocking', $hash->{NAME}."|".$streamURI, 'DLNARenderer_finishedSetAVTransportURIBlocking');
      }
    }
  } elsif ($ctrlParam eq "stream") {
    #stream = set stream URI and play
    $streamURI = $params[0];
    BlockingCall('DLNARenderer_setAVTransportURIBlocking', $hash->{NAME}."|".$streamURI, 'DLNARenderer_finishedSetAVTransportURIBlocking');
  } else {
      if($hash->{helper}{caskeid}) {
        return SetExtensions($hash, $caskeidCommandList." ".$stdCommandList, $name, $ctrlParam, @params);       
      } else {
        return SetExtensions($hash, $stdCommandList, $name, $ctrlParam, @params);
      }
  }
  
  return undef;
}

##############################
##### SET FUNCTIONS ##########
##############################
#TODO move everything from _Set to set functions
sub DLNARenderer_setAVTransportURIBlocking($) {
  my ($string) = @_;
  my ($name, $streamURI) = split("\\|", $string);
  my $hash = $main::defs{$name};
  my $return = "$name|$streamURI";
  
  DLNARenderer_upnpSetAVTransportURI($hash, $streamURI);

  return $return;
}

sub DLNARenderer_finishedSetAVTransportURIBlocking($) {
  my ($string) = @_;
  my @params = split("\\|", $string);
  my $name = $params[0];
  my $hash = $defs{$name};
  
  readingsSingleUpdate($hash,"stream",$params[1],1);
  
  DLNARenderer_play($hash);
  
  return undef;
}

sub DLNARenderer_play($) {
  my ($hash) = @_;
  
  #start play
  if($hash->{helper}{caskeid}) {
    DLNARenderer_upnpSyncPlay($hash, $hash->{helper}{device});
  } else {
    DLNARenderer_upnpPlay($hash);
  }
  
  return undef;
}

###########################
##### CASKEID #############
###########################
# BTCaskeid
sub DLNARenderer_enableBTCaskeid {
  my ($hash, $dev) = @_;
  DLNARenderer_upnpAddUnitToGroup($hash, $dev, "4DAA44C0-8291-11E3-BAA7-0800200C9A66", "Bluetooth");
}

sub DLNARenderer_disableBTCaskeid {
  my ($hash, $dev) = @_;
  DLNARenderer_upnpRemoveUnitFromGroup($hash, $dev, "4DAA44C0-8291-11E3-BAA7-0800200C9A66");
}

# Stereo Mode
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

sub DLNARenderer_setMultiChannelSpeaker {
  my ($hash, $mode, $uuid, $name) = @_;
  my $uuidStr;
  
  if($mode eq "standalone") {
    DLNARenderer_upnpSetMultiChannelSpeaker($hash, "STANDALONE", "", "", "STANDALONE_SPEAKER");
  } elsif($mode eq "left") {
    DLNARenderer_upnpSetMultiChannelSpeaker($hash, "STEREO", $uuid, $name, "LEFT_FRONT");
  } elsif($mode eq "right") {
    DLNARenderer_upnpSetMultiChannelSpeaker($hash, "STEREO", $uuid, $name, "RIGHT_FRONT");
  }
  
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

# SessionManagement
sub DLNARenderer_createSession {
  my ($hash, $dev) = @_;
  return DLNARenderer_upnpCreateSession($hash, "FHEM_Session")->getValue("SessionID");
}

sub DLNARenderer_getSession {
  my ($hash, $dev) = @_;
  return DLNARenderer_upnpGetSession($hash)->getValue("SessionID");
}

sub DLNARenderer_destroySession {
  my ($hash, $dev, $session) = @_;
  
  return DLNARenderer_upnpDestroySession($hash, $session);
}

sub DLNARenderer_destroyCurrentSession {
  my ($hash, $dev) = @_;
  
  my $session = DLNARenderer_getSession($hash, $dev);
  
  if($session ne "") {
    DLNARenderer_destroySession($hash, $dev, $session);
  }
}

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

sub DLNARenderer_addUnitToSession {
  my ($hash, $dev, $uuid, $session) = @_;
  
  return DLNARenderer_upnpAddUnitToSession($hash, $session, $uuid);
}

sub DLNARenderer_removeUnitFromSession {
  my ($hash, $dev, $uuid, $session) = @_;
  
  return DLNARenderer_upnpRemoveUnitFromSession($hash, $session, $uuid);
}

# Group Definitions
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

##############################
####### UPNP FUNCTIONS #######
##############################
sub DLNARenderer_upnpPause {
  my ($hash) = @_;
  return DLNARenderer_upnpCallAVTransport($hash, "Pause", 0);
}

sub DLNARenderer_upnpSetAVTransportURI {
  my ($hash, $stream) = @_;
  return DLNARenderer_upnpCallAVTransport($hash, "SetAVTransportURI", 0, $stream, "");
}

sub DLNARenderer_upnpStop {
  my ($hash) = @_;
  return DLNARenderer_upnpCallAVTransport($hash, "Stop", 0);
}

sub DLNARenderer_upnpSeek {
  my ($hash, $seekTime) = @_;
  return DLNARenderer_upnpCallAVTransport($hash, "Seek", 0, "REL_TIME", $seekTime);
}

sub DLNARenderer_upnpNext {
  my ($hash) = @_;
  return DLNARenderer_upnpCallAVTrasnport($hash, "Next", 0);
}

sub DLNARenderer_upnpPrevious {
  my ($hash) = @_;
  return DLNARenderer_upnpCallAVTrasnport($hash, "Previous", 0);
}

sub DLNARenderer_upnpPlay {
  my ($hash) = @_;
  return DLNARenderer_upnpCallAVTransport($hash, "Play", 0, 1);
}

sub DLNARenderer_upnpSyncPlay($$) {
  my ($hash, $dev) = @_;
  return DLNARenderer_upnpCallAVTransport($hash, "SyncPlay", 0, 1, "REL_TIME", "", "", "", "DeviceClockId");
}

sub DLNARenderer_upnpCallAVTransport {
  my ($hash, $method, @args) = @_;
  return DLNARenderer_upnpCall($hash, 'urn:upnp-org:serviceId:AVTransport', $method, @args);
}

sub DLNARenderer_upnpSetMultiChannelSpeaker {
  my ($hash, @args) = @_;
  return DLNARenderer_upnpCallSpeakerManagement($hash, "SetMultiChannelSpeaker", @args);
}

sub DLNARenderer_upnpCallSpeakerManagement {
  my ($hash, $method, @args) = @_;
  return DLNARenderer_upnpCall($hash, 'urn:pure-com:serviceId:SpeakerManagement', $method, @args);
}

sub DLNARenderer_upnpAddUnitToSession {
  my ($hash, $session, $uuid) = @_;
  return DLNARenderer_upnpCallSessionManagement($hash, "AddUnitToSession", $session, $uuid);
}

sub DLNARenderer_upnpRemoveUnitToSession {
  my ($hash, $session, $uuid) = @_;
  return DLNARenderer_upnpCallSessionManagement($hash, "RemoveUnitToSession", $session, $uuid);
}

sub DLNARenderer_upnpDestroySession {
  my ($hash, $session) = @_;
  return DLNARenderer_upnpCallSessionManagement($hash, "DestroySession", $session);
}

sub DLNARenderer_upnpCreateSession {
  my ($hash, $name) = @_;
  return DLNARenderer_upnpCallSessionManagement($hash, "CreateSession", $name);
}

sub DLNARenderer_upnpGetSession {
  my ($hash) = @_;
  return DLNARenderer_upnpCallSessionManagement($hash, "GetSession");
}

sub DLNARenderer_upnpAddUnitToGroup {
  my ($hash, $dev, $unit, $name) = @_;
  return DLNARenderer_upnpCallSpeakerManagement($hash, "AddUnitToGroup", $unit, $name, "");
}

sub DLNARenderer_upnpRemoveUnitFromGroup {
  my ($hash, $dev, $unit) = @_;
  return DLNARenderer_upnpCallSpeakerManagement($hash, "RemoveUnitToGroup", $unit);
}

sub DLNARenderer_upnpCallSessionManagement {
  my ($hash, $method, @args) = @_;
  return DLNARenderer_upnpCall($hash, 'urn:pure-com:serviceId:SessionManagement', $method, @args);
}

sub DLNARenderer_upnpSetVolume {
  my ($hash, $targetVolume) = @_;
  return DLNARenderer_upnpCallRenderingControl($hash, "SetVolume", 0, "Master", $targetVolume);
}

sub DLNARenderer_upnpCallRenderingControl {
  my ($hash, $method, @args) = @_;
  return DLNARenderer_upnpCall($hash, 'urn:upnp-org:serviceId:RenderingControl', $method, @args);
}

sub DLNARenderer_upnpCall {
  my ($hash, $service, $method, @args) = @_;
  my $upnpService = $hash->{helper}{device}->getService($service);
  my $upnpServiceCtrlProxy = $upnpService->controlProxy();
  
  eval {
    $upnpServiceCtrlProxy->$method(@args);
    Log3 $hash, 5, "DLNARenderer: $service, $method(".join(",",@args).") succeed.";
  };
  
  if($@) {
    Log3 $hash, 3, "DLNARenderer: $service, $method(".join(",",@args).") failed, $@";
    return "DLNARenderer: $method failed.";
  }
}

##############################
####### EVENT HANDLING #######
##############################
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
        
        #update state
        my $transportState = ReadingsVal($hash->{NAME}, "transportState", "");
        if(ReadingsVal($hash->{NAME}, "presence", "") ne "offline") {
          if($transportState eq "PAUSED_PLAYBACK") {
              readingsSingleUpdate($hash, "state", "paused", 1);
          } elsif($transportState eq "PLAYING") {
              readingsSingleUpdate($hash, "state", "playing", 1);
          } elsif($transportState eq "TRANSITIONING") {
              readingsSingleUpdate($hash, "state", "buffering", 1);
          } elsif($transportState eq "STOPPED") {
              readingsSingleUpdate($hash, "state", "stopped", 1);
          } elsif($transportState eq "NO_MEDIA_PRESENT") {
              readingsSingleUpdate($hash, "state", "online", 1);
          }
        }
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
  }
  
  return undef;
}

##############################
####### DISCOVERY ############
##############################
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
      
      #set online
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

sub DLNARenderer_removedDevice($$) {
  my ($hash, $device) = @_;
  my $deviceHash = DLNARenderer_getHashByUDN($hash, $device->UDN());
  
  readingsSingleUpdate($deviceHash, "presence", "offline", 1);
  readingsSingleUpdate($deviceHash, "state", "offline", 1);
}

###############################
##### GET PLAYER FUNCTIONS ####
###############################
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

###############################
###### UTILITY FUNCTIONS ######
###############################
sub DLNARenderer_newChash($$$)
{
  my ($hash,$socket,$chash) = @_;

  $chash->{TYPE}  = $hash->{TYPE};

  $chash->{NR}    = $devcount++;

  $chash->{phash} = $hash;
  $chash->{PNAME} = $hash->{NAME};

  $chash->{CD}    = $socket;
  $chash->{FD}    = $socket->fileno();

  $chash->{PORT}  = $socket->sockport if( $socket->sockport );

  $chash->{TEMPORARY} = 1;
  $attr{$chash->{NAME}}{room} = 'hidden';

  $defs{$chash->{NAME}}       = $chash;
  $selectlist{$chash->{NAME}} = $chash;
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
