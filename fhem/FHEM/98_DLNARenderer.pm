############################################################################
# 2016-03-21, v2.0.0, dominik.karall@gmail.com $
#
# v2.0.0 - 20160321
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
# - set presence=offline if device wasn't found for X minutes
# - implement events from DLNA devices (MediaInfo)
# - implement stereo mode for caskeid devices
# - implement speak functions
# - check Standby -> Online signal
# - remove attributes (scanInterval, ignoreUDNs, multiRoomGroups) from play devices
#
############################################################################

package main;

use strict;
use warnings;

use Blocking;

use MIME::Base64;
use Net::UPnP::ControlPoint;
use Net::UPnP::Device;
use Net::UPnP::AV::MediaRenderer;

###################################
sub
DLNARenderer_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "DLNARenderer_Set";
  $hash->{DefFn}     = "DLNARenderer_Define";
  $hash->{UndefFn}   = "DLNARenderer_Undef";
  $hash->{AttrFn}    = "DLNARenderer_Attribute";
  $hash->{AttrList}  = "ignoreUDNs scanInterval ".$readingFnAttributes;
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

sub
DLNARenderer_startUPnPScan($)
{
  my ($hash) = @_;

  if(!defined($hash->{helper}{SCAN_PID})) {
    $hash->{helper}{SCAN_PID} = BlockingCall("DLNARenderer_startUPnPScanBlocking", $hash->{NAME}."|".$hash, "DLNARenderer_finishedUPnPScan");
  }

  return undef;
}

sub
DLNARenderer_startUPnPScanBlocking($)
{
  my ($string) = @_;
  my ($name, $hash) = split("\\|", $string);
  my $return = "$name";
  $hash = $main::defs{$name};
  
  my $obj = Net::UPnP::ControlPoint->new();
  my @dev_list = $obj->search(st =>'urn:schemas-upnp-org:device:MediaRenderer:1', mx => 3);
  
  foreach my $dev (@dev_list) {
    Log3 $hash, 5, "DLNARenderer: Found device ".$dev->getfriendlyname();
    $return = $return."|".encode_base64($dev->getssdp(), "")."|".encode_base64($dev->getdescription(), "");
  }
  
  return $return;
}

sub
DLNARenderer_finishedUPnPScan($)
{
  my ($string) = @_;
  my @params = split("\\|", $string);
  my $name = shift(@params);
  my $hash = $main::defs{$name};

  delete($hash->{helper}{SCAN_PID});
  InternalTimer(gettimeofday() + AttrVal($hash->{NAME}, "scanInterval", 60), 'DLNARenderer_startUPnPScan', $hash, 0);
  
  for(my $i=0; $i<@params; $i=$i+2) {
    my $ssdp = decode_base64($params[$i]);
    my $description = decode_base64($params[$i+1]);
    my $dev = Net::UPnP::Device->new();
    $dev->setssdp($ssdp);
    $dev->setdescription($description);
    my $udn = $dev->getudn();
    
    #TODO check for BOSE UDN
    
    #ignoreUDNs
    next if(AttrVal($hash->{NAME}, "ignoreUDNs", "") =~ /$udn/);
    
    my $foundDevice = 0;
    my @allDLNARenderers = DLNARenderer_getAllDLNARenderers($hash);
    foreach my $DLNARendererHash (@allDLNARenderers) {
      if($DLNARendererHash->{UDN} eq $dev->getudn()) {
        $foundDevice = 1;
      }
    }
    
    if(!$foundDevice) {
      my $uniqueDeviceName = "DLNA_".substr($dev->getudn(),29,12);
      CommandDefine(undef, "$uniqueDeviceName DLNARenderer ".$dev->getudn());
      CommandAttr(undef,"$uniqueDeviceName alias ".$dev->getfriendlyname());
      CommandAttr(undef,"$uniqueDeviceName devStateIcon on:audio_volume_high off:audio_volume_mute");
      CommandAttr(undef,"$uniqueDeviceName webCmd volume");
      Log3 $hash, 3, "DLNARenderer: Created device $uniqueDeviceName for ".$dev->getfriendlyname();
      
      #update list
      @allDLNARenderers = DLNARenderer_getAllDLNARenderers($hash);
    }
  
    foreach my $DLNARendererHash (@allDLNARenderers) {
      if($DLNARendererHash->{UDN} eq $dev->getudn()) {
        #device found, update data
        $DLNARendererHash->{helper}{device} = $dev;
        
        #set render_service
        my $render_service;
        my @service_list = $dev->getservicelist();
        foreach my $service (@service_list) {
          my @serv_parts = split(/:/, $service->getservicetype());
          if ($serv_parts[3] eq "RenderingControl") {
            $render_service = $service;
          }
        }
        $DLNARendererHash->{helper}{render_service} = $render_service;
        readingsSingleUpdate($DLNARendererHash,"presence","online",1);
        
        #check caskeid
        if($dev->getservicebyname('urn:schemas-pure-com:service:SessionManagement:1')) {
          $DLNARendererHash->{helper}{caskeid} = 1;
          readingsSingleUpdate($DLNARendererHash,"multiRoomSupport","1",1);
        } else {
          readingsSingleUpdate($DLNARendererHash,"multiRoomSupport","0",1);
        }
        
        readingsSingleUpdate($DLNARendererHash,"friendlyName",$dev->getfriendlyname(),1);
        
        DLNARenderer_updateVolume($DLNARendererHash);
        
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

sub
DLNARenderer_updateVolume($)
{
  my ($hash) = @_;
  my $render_service = $hash->{helper}{render_service};
  
  #get current volume
  if ($render_service) {
    my %action_renderctrl_in_args = (
      'InstanceID' => 0,
      'Channel' => 'Master'
    );
    my $render_service_res = $render_service->postcontrol('GetVolume', \%action_renderctrl_in_args);
    my $volume_out_arg = $render_service_res->getargumentlist();
    my $currVolume = $volume_out_arg->{'CurrentVolume'};
    if (defined($hash->{READINGS}{volume}) and $hash->{READINGS}{volume}{VAL} ne $currVolume) {
      readingsSingleUpdate($hash, "volume", $currVolume, 1);
    }
  }
  
  return undef;
}

###################################
sub
DLNARenderer_setAVTransport($)
{
  my ($string) = @_;
  my ($name, $streamURI) = split("\\|", $string);
  my $hash = $main::defs{$name};
  my $return = "$name|$streamURI";

  #streamURI received
  Log3 $hash, 4, "DLNARenderer: start play for ".$streamURI;
  my $renderer = Net::UPnP::AV::MediaRenderer->new();
  $renderer->setdevice($hash->{helper}{device});

  Log3 $hash, 5, "DLNARenderer: setAVTransportURI Start";
  $renderer->setAVTransportURI(CurrentURI => $streamURI);
  Log3 $hash, 5, "DLNARenderer: setAVTransportURI End";

  return $return;
}

###################################
sub
DLNARenderer_finishedSetAVTransport($)
{
  my ($string) = @_;
  my @params = split("\\|", $string);
  my $name = $params[0];
  my $hash = $defs{$name};
  
  readingsSingleUpdate($hash,"stream",$params[1],1);
  
  #start play
  if($hash->{helper}{caskeid}) {
    DLNARenderer_syncPlay($hash, $hash->{helper}{device});
  } else {
    my $renderer = Net::UPnP::AV::MediaRenderer->new();
    $renderer->setdevice($hash->{helper}{device});
    $renderer->play();
  }
  
  readingsSingleUpdate($hash,"state","on",1);
  
  return undef;
}

sub
DLNARenderer_syncPlay($$)
{
  my ($hash, $dev) = @_;
  my $avtrans_service = $dev->getservicebyname('urn:schemas-upnp-org:service:AVTransport:1');
  my %req_arg = (
        'InstanceID' => "0",
        'Speed' => 1,
        'ReferencePositionUnits' => "REL_TIME",
        'ReferenceClockId' => "DeviceClockId"
  );
  my $res = $avtrans_service->postaction("SyncPlay", \%req_arg);
  if($res->getstatuscode() == 200) {
    #ok
  }
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
  my $service = $dev->getservicebyname('urn:schemas-pure-com:service:SpeakerManagement:1');
  
  my %req_arg = (
        'ID' => $unit,
        'Name' => $name,
        'Metadata' => ""
  );
  
  my $res = $service->postaction("AddToGroup", \%req_arg);
  if($res->getstatuscode() == 200) {
    #ok
  }
}

sub DLNARenderer_removeUnitFromGroup {
  my ($hash, $dev, $unit) = @_;
  my $service = $dev->getservicebyname('urn:schemas-pure-com:service:SpeakerManagement:1');
  
  my %req_arg = (
        'ID' => $unit
  );
  
  my $res = $service->postaction("RemoveFromGroup", \%req_arg);
  if($res->getstatuscode() == 200) {
    #ok
  }
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
  my $conn_service = $dev->getservicebyname('urn:schemas-pure-com:service:SessionManagement:1');

  my %req_arg = (
        'MetaData' => ""
  );
  my $session = $conn_service->postaction("CreateSession", \%req_arg);
  my $res = $session->getargumentlist();
  Log3 $hash, 4, "DLNARenderer: CreateSession => ID: ".$res->{'SessionID'};
  return $res->{'SessionID'};
}

sub DLNARenderer_getSession {
  my ($hash, $dev) = @_;
  my $conn_service = $dev->getservicebyname('urn:schemas-pure-com:service:SessionManagement:1');

  my %req_arg = ();
  my $session = $conn_service->postaction("GetSession", \%req_arg);
  my $res = $session->getargumentlist();
  Log3 $hash, 4, "DLNARenderer: GetSession => ID: ".$res->{'SessionID'};
  return $res->{'SessionID'};
}

sub DLNARenderer_addUnitToSession {
  my ($hash, $dev, $uuid, $session) = @_;
  my $conn_service = $dev->getservicebyname('urn:schemas-pure-com:service:SessionManagement:1');

  my %req_arg = (
        'SessionID' => $session,
        'UUID' => $uuid
  );
  my $res = $conn_service->postaction("AddUnitToSession", \%req_arg);
  if($res->getstatuscode() == 200) {
    #ok
  }
}

sub DLNARenderer_removeUnitFromSession {
  my ($hash, $dev, $uuid, $session) = @_;
  my $conn_service = $dev->getservicebyname('urn:schemas-pure-com:service:SessionManagement:1');

  my %req_arg = (
        'SessionID' => $session,
        'UUID' => $uuid
  );
  my $res = $conn_service->postaction("RemoveUnitFromSession", \%req_arg);
  if($res->getstatuscode() == 200) {
    #ok
  }
}

sub DLNARenderer_destroySession {
  my ($hash, $dev, $sessionId) = @_;
  my $conn_service = $dev->getservicebyname('urn:schemas-pure-com:service:SessionManagement:1');

  my %req_arg = (
        'SessionID' => $sessionId
  );
  my $res = $conn_service->postaction("DestroySession", \%req_arg);
  if($res->getstatuscode() == 200) {
    #ok
  }
}

sub DLNARenderer_saveGroupAs {
  my ($hash, $dev, $groupName) = @_;
  my $mainDlnaRendererHash = DLNARenderer_getMainDLNARenderer($hash);
  
  #return if(!defined($mainDlnaRendererHash));
  
  #my $currentGroupSettings = AttrVal($mainDlnaRendererHash->{NAME}, "multiRoomGroups", "");
  #$currGroupSettings .= "," if($currGroupSettings ne "");
  #TODO implement feature
  
  #CommandAttr(undef, "$mainDlnaRendererHash->{NAME} attr ")  
}

###################################
sub
DLNARenderer_Define($$)
{
  my ($hash, $def) = @_;
  my @param = split("[ \t][ \t]*", $def);
  
  #init caskeid clients for multiroom
  $hash->{helper}{caskeidClients} = "";
  $hash->{helper}{caskeid} = 0;
  
  if(@param < 3) {
    #main
    $hash->{UDN} = 0;
    Log3 $hash, 3, "DLNARenderer: DLNA Renderer v2.0.0 BETA";
    InternalTimer(gettimeofday() + 10, 'DLNARenderer_startUPnPScan', $hash, 0);
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
  
  return undef;
}

###################################
sub
DLNARenderer_Undef($)
{
  my ($hash) = @_;
  
  #stop blocking call
  BlockingKill($hash->{helper}{SCAN_PID}) if(defined($hash->{helper}{SCAN_PID}));
  
  RemoveInternalTimer($hash);
  return undef;
}
###################################
sub
DLNARenderer_Set($@)
{
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
             "addUnit:".$hash->{helper}{caskeidClients}." ".
             "playEverywhere:noArg stopPlayEverywhere:noArg ".
             "removeUnit:".ReadingsVal($hash->{NAME}, "multiRoomUnits", "")." ".
             "enableBTCaskeid:noArg disableBTCaskeid:noArg";
    } else {
      return "Unknown argument, choose one of on:noArg off:noArg play:noArg stop:noArg stream volume:slider,0,1,100";
    }
  }
    
  # check device presence
  if (!defined($dev) or $hash->{READINGS}{presence}{VAL} eq "offline") {
    return "DLNARenderer: Currently searching for device $hash->{DEVNAME}...";
  }
  
  # set volume
  if($ctrlParam eq "volume"){
    if(!$render_service) {
      Log3 $hash, 3, "DLNARenderer: No volume control possible for this device";
      return undef;
    }
    return "DLNARenderer: Unknown argument, choose one of on off play stop <url> volume:slider,0,1,100" if (int(@param) < 3);
    
    my $newVolume = $param[2];
    my %action_renderctrl_in_args = (
      'InstanceID' => 0,
      'Channel' => 'Master',
      'DesiredVolume' => $newVolume
    );
    my $render_service_res = $render_service->postcontrol('SetVolume', \%action_renderctrl_in_args);
    readingsSingleUpdate($hash, "volume", $newVolume, 1);
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
    my @caskeidClients = DLNARenderer_getAllDLNARenderersWithCaskeid($hash);
    foreach my $client (@caskeidClients) {
      if(ReadingsVal($client->{NAME}, "friendlyName", "") eq $param[2]) {
        my @multiRoomUnits = split(",", ReadingsVal($hash->{NAME}, "multiRoomUnits", ""));
        foreach my $unit (@multiRoomUnits) {
          #skip if unit is already part of the session
          return undef if($unit eq $param[2]);
        }
        #add unit to session
        DLNARenderer_addUnitToPlay($hash, $dev, substr($client->{UDN},5));
        my $currMultiRoomUnits = ReadingsVal($hash->{NAME}, "multiRoomUnits","");
        if($currMultiRoomUnits ne "") {
          readingsSingleUpdate($hash, "multiRoomUnits", $currMultiRoomUnits.",".$param[2], 1);
        } else {
          readingsSingleUpdate($hash, "multiRoomUnits", $param[2], 1);
        }
        return undef;
      }
    }
    return "DLNARenderer: No unit $param[2] found.";
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
    my $renderer = Net::UPnP::AV::MediaRenderer->new();
    $renderer->setdevice($dev);
    $renderer->stop();
    readingsSingleUpdate($hash,"state","off",1);
    return undef;
  }
  
  # on/play
  if($ctrlParam eq "on" || $ctrlParam eq "play"){
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

  readingsSingleUpdate($hash, "state", "buffering", 1);
  BlockingCall('DLNARenderer_setAVTransport', $hash->{NAME}."|".$streamURI, 'DLNARenderer_finishedSetAVTransport');
  
  return undef;
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
