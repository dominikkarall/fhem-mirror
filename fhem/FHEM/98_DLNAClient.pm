##############################################
# 2016-01-05, v1.11, dominik $
#   v1.11: - FIXED: support all versions of RenderingControl UPnP service (by MichaelT)
#
# DLNA Module to play given URLs on a DLNA Renderer
# and control their volume
#
##############################################
package main;

use strict;
use warnings;
use threads;
use Thread::Queue;
use Net::UPnP::ControlPoint;
use Net::UPnP::AV::MediaRenderer;
use Net::UPnP::ActionResponse;
use Net::UPnP::AV::MediaServer;

###################################
sub
DLNAClient_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "DLNAClient_Set";
  $hash->{DefFn}     = "DLNAClient_Define";
  $hash->{UndefFn}   = "DLNAClient_Undef";
}

###################################
sub
DLNAClient_ScanDevicesThread ($)
{
  my ($hash) = @_;  
  my @dev_list = ();
  my $retry_cnt = 0;
  my $input = "";
  my $currentDevice = undef;
  
  my $scanQueue = $hash->{scanQueue};
  my $threadInput = $hash->{threadInput};
  
  #dequeue blocks the thread till next input
  while ($input = $threadInput->dequeue()) {
    Log3 $hash, 5, "DLNAClient: thread input: ".$input;
    
    if ($input eq "stopScan") {
      #stop thread immediately
      return undef;
    } elsif ($input eq "scanNow") {
      #start scan process now
      
      #empty scanQueue
      while ($scanQueue->pending()) {
        $scanQueue->dequeue_nb();
      }
      
      $retry_cnt = 0;
      @dev_list = ();
      while (@dev_list <= 0) {
        Log3 $hash, 4,  "DLNAClient: Searching for renderers...";
        my $obj = Net::UPnP::ControlPoint->new();
        @dev_list = $obj->search(st =>'urn:schemas-upnp-org:device:MediaRenderer:1', mx => 5);
        $retry_cnt++;
        if ($retry_cnt >= 3) {
          Log3 $hash, 4, "DLNAClient: [!] No renderers found.";
          last;
        }
      }

      my $devNum = 0;
      my $dev;
      my $foundDevice = 0;
      
      foreach $dev (@dev_list) {
        my $device_type = $dev->getdevicetype();
        my $friendlyname = $dev->getfriendlyname(); 
        Log3 $hash, 4, "DLNAClient: found [$devNum] : device name: " . $friendlyname;
        
        if ($device_type ne 'urn:schemas-upnp-org:device:MediaRenderer:1') {
          next;
        }
        
        $devNum++;
        if ($friendlyname ne $hash->{DEVNAME}) {
          Log3 $hash, 5,  "DLNAClient: skipping this device.";
          next;
        } else {
          Log3 $hash, 5, "DLNAClient: matching device.";
          
          #add new device to scanQueue
          $scanQueue->enqueue($dev);
          $currentDevice = $dev;
          $foundDevice = 1;
          last;
        }
      }
      if ($foundDevice==0) {
        Log3 $hash, 4, "DLNAClient: device offline.";
        if (!defined($currentDevice)) {
          $scanQueue->enqueue("offline");
        }
      }
    } else {
      #streamURI received
      my $streamURI = $input;
      Log3 $hash, 5, "DLNAClient: start play for ".$streamURI;
      my $renderer = Net::UPnP::AV::MediaRenderer->new();
      $renderer->setdevice($currentDevice);
      
      #more testing required to enable streammetadata
      
      #Windows Media Player:
      #<res size="57691" duration="0:00:01.440" bitrate="40000" protocolInfo="http-get:*:audio/mpeg:DLNA.ORG_PN=MP3;DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000"
      #sampleFrequency="48000" bitsPerSample="16" nrAudioChannels="2">http://192.168.1.215:10246/MDEServer/3A255347-F53C-47DD-9570-A327F58B3D69/1000.mp3</res>
      my $DIDLHeader = '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">';
      my $DIDLFooter = '</DIDL-Lite>';
      my $streamMetaData = $DIDLHeader.'<item id="1000" parentID="0" restricted="1"><dc:title>'.$streamURI.'</dc:title><res protocolInfo="http-get:*:audio/mpeg:DLNA.ORG_PN=MP3;DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000">'.$streamURI.'</res></item>'.$DIDLFooter;

      Log3 $hash, 5, "DLNAClient: setAVTransportURI Start";
      $renderer->setAVTransportURI(CurrentURI => $streamURI); #, CurrentURIMetaData => $streamMetaData);
      Log3 $hash, 5, "DLNAClient: setAVTransportURI End";
      $renderer->play();
      Log3 $hash, 5, "DLNAClient: play started";
      
      #FIXME readingsSingleUpdate doesn't work from separate thread
      #readingsSingleUpdate($hash,"stream",$streamURI,1);
      #readingsSingleUpdate($hash,"state","on",1);
    }
  }
  return undef;
}

###################################
sub
DLNAClient_StartScanThread($)
{
  my ($hash) = @_;
  my $scanQueue = $hash->{scanQueue};
  my $threadInput = $hash->{threadInput};
  
  #take new device from queue
  if ($scanQueue->pending()) {
    $hash->{dlnaDevice} = $scanQueue->dequeue_nb();
    
    if ($hash->{dlnaDevice} eq "offline") {
      $hash->{dlnaDevice} = undef;
      readingsSingleUpdate($hash, "state", "offline", 1);
    } else {
      if ($hash->{READINGS}{state}{VAL} eq "offline") {
        readingsSingleUpdate($hash, "state", "off", 1);
      }
    }
  }
  
  if (!defined($hash->{scanThread})) {
    #set device state offline at startup
    readingsSingleUpdate($hash, "state", "offline", 1);
    $hash->{scanThread} = threads->create(\&DLNAClient_ScanDevicesThread, $hash);
    $hash->{scanThread}->detach();
  }
  $hash->{threadInput}->enqueue("scanNow");
  
  InternalTimer(gettimeofday() + 120, 'DLNAClient_StartScanThread', $hash, 0);
  
  return undef;  
}

###################################
sub
DLNAClient_Define($$)
{
  my ($hash, $def) = @_;
  my @param = split("[ \t][ \t]*", $def);
  
  if (!defined($hash->{scanQueue})) {
    $hash->{scanQueue} = Thread::Queue->new();
    $hash->{threadInput} = Thread::Queue->new();
  }

  return "too few parameters: define <name> DLNAClient <DLNAName>" if(int(@param) < 3);
  
  my $name            = shift @param;
  my $type            = shift @param;
  my $clientName      = join(" ", @param);
  $hash->{DEVNAME} = $clientName;
  
  if (!defined($hash->{scanThread})) {
    DLNAClient_StartScanThread($hash);
  }
  
  $hash->{threadInput}->enqueue("scanNow");

  return undef;
}

###################################
sub
DLNAClient_Undef($)
{
  my ($hash) = @_;
  my $threadInput = $hash->{threadInput};
  
  #send stopScan
  $threadInput->enqueue("stopScan");
  
  RemoveInternalTimer($hash);
  return undef;
}
###################################
sub
DLNAClient_Set($@)
{
  my ($hash, @param) = @_;
  my $deviceName = $hash->{DEVNAME};
  my $dev = $hash->{dlnaDevice};
  my $scanQueue = $hash->{scanQueue};
  my $threadInput = $hash->{threadInput};
  my $streamURI = "";
  
  # check parameters
  return "no set value specified" if(int(@param) < 1);
  my $ctrlParam = $param[1];
  
  if ($ctrlParam eq "?" || (($ctrlParam eq "volume" || $ctrlParam eq "stream") && int(@param) < 3)) {
    return "Unknown argument, choose one of on:noArg off:noArg play:noArg stop:noArg stream volume:slider,0,1,100";
  }
    
  # check device presence
  if (!defined($dev)) {
    $threadInput->enqueue("scanNow");
    return "DLNAClient: Currently searching for device $hash->{DEVNAME}...";
  }
  
  my $service;
  my $render_service;
  my @service_list = $dev->getservicelist();
  foreach $service (@service_list) {
    my @serv_parts = split(/:/, $service->getservicetype());
    if ($serv_parts[3] eq "RenderingControl") {
      $render_service = $service;
    }
  }
  if ($render_service) {
    my %action_renderctrl_in_args = (
      'InstanceID' => 0,
      'Channel' => 'Master'
    );
    my $render_service_res = $render_service->postcontrol('GetVolume', \%action_renderctrl_in_args);
    my $volume_out_arg = $render_service_res->getargumentlist();
    my $currVolume = $volume_out_arg->{'CurrentVolume'};
    readingsSingleUpdate($hash, "volume", $currVolume, 1);
  }
  
  # set volume
  if($ctrlParam eq "volume"){
    if (!$render_service) {
      Log3 $hash, 3, "DLNAClient: No volume control possible for this device ($deviceName)";
      return undef;
    }
    return "DLNAClient: Unknown argument, choose one of on off play stop <url> volume:slider,0,1,100" if (int(@param) < 3);
    
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
  if (!$streamURI) {
    if($ctrlParam eq "stream"){
      $streamURI = $param[2];
    } elsif ($ctrlParam ne "on" or $ctrlParam ne "play") {
      $streamURI = $ctrlParam;
    } else {
      return "use set <device> stream <URI> first";
    }
  }
  
  Log3 $hash, 5, "DLNAClient: start Thread with ".$streamURI;
  $threadInput->enqueue($streamURI);
  readingsSingleUpdate($hash,"stream",$streamURI,1);
  readingsSingleUpdate($hash,"state","on",1);
  
  return undef;
  
  #planned for next release
  #return "Unknown argument, use \"set <device> stream URI\" instead";
}

1;

=pod
=begin html

<a name="DLNAClient"></a>
<h3>DLNAClient</h3>
<ul>

  Define a DLNA client. A DLNA client can take an URL to play via <a href="#set">set</a>.
  
  <br><br>

  <a name="DLNAClientdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; DLNAClient &lt;name&gt;</code>
    <br><br>

    Example:
    <ul>
      <code>define MyPlayer DLNAClient NP2500</code><br>
      Here, NP2500 is the name of the player as it announces itself to the network.<br/>
      <code>set MyPlayer stream http://link-to-online-stream/file.m3u</code><br>
    </ul>
  </ul>
  <br>

  <a name="DLNAClientset"></a>
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
