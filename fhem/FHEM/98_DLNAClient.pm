##############################################
# 2016-02-16, v1.23, dominik $
#
# v1.23
# - BUGFIX: call GetVolume only after scan
# - FEATURE: add presence based on first scan
#
# v1.22
# - CHANGED: set state offline on startup and off when found
# - BUGFIX: add use Blocking
# - FEATURE: log version on startup
#
# v1.21
# - BUGFIX: fix handling if device was not found
#
# v1.20
# - CHANGED: removed all iThreads
# - CHANGED: use BlockingCall for upnp search
#
# DLNA Module to play given URLs on a DLNA Renderer
# and control their volume
#
# TODO
# - set presence=offline if device wasn't found for X minutes
#
##############################################
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
DLNAClient_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "DLNAClient_Set";
  $hash->{DefFn}     = "DLNAClient_Define";
  $hash->{UndefFn}   = "DLNAClient_Undef";
}

sub
DLNAClient_startUPnPScan($)
{
  my ($hash) = @_;

  if(!defined($hash->{helper}{SCAN_PID})) {
    $hash->{helper}{SCAN_PID} = BlockingCall("DLNAClient_startUPnPScanBlocking", $hash->{NAME}."|".$hash, "DLNAClient_finishedUPnPScan");
  }

  return undef;
}

sub
DLNAClient_startUPnPScanBlocking($)
{
  my ($string) = @_;
  my ($name, $hash) = split("\\|", $string);
  my $return = "$name";
  $hash = $main::defs{$name};
  
  my $obj = Net::UPnP::ControlPoint->new();
  my @dev_list = $obj->search(st =>'urn:schemas-upnp-org:device:MediaRenderer:1', mx => 3);
  
  foreach my $dev (@dev_list) {
    Log3 $hash, 5, "DLNAClient: Found device ".$dev->getfriendlyname();
    if($dev->getfriendlyname() eq $hash->{DEVNAME}) {
      $return = $return."|".encode_base64($dev->getssdp(), "")."|".encode_base64($dev->getdescription(), "");
      Log3 $hash, 4, "DLNAClient: Found specified device ".$dev->getfriendlyname();
    }
  }
  
  return $return;
}

sub
DLNAClient_finishedUPnPScan($)
{
  my ($string) = @_;
  my ($name, $ssdp, $description) = split("\\|", $string);
  my $hash = $main::defs{$name};

  delete($hash->{helper}{SCAN_PID});
  InternalTimer(gettimeofday() + 60, 'DLNAClient_startUPnPScan', $hash, 0);

  if(!defined($ssdp)) {
    Log3 $hash, 4, "DLNAClient: DLNA device not found.";
    return undef;
  }
  
  $ssdp = decode_base64($ssdp);
  $description = decode_base64($description);

  my $dev = Net::UPnP::Device->new();
  $dev->setssdp($ssdp);
  $dev->setdescription($description);
  
  $hash->{helper}{device} = $dev;
    
  #set render_service
  my $render_service;
  my @service_list = $dev->getservicelist();
  foreach my $service (@service_list) {
    my @serv_parts = split(/:/, $service->getservicetype());
    if ($serv_parts[3] eq "RenderingControl") {
      $render_service = $service;
    }
  }
  $hash->{helper}{render_service} = $render_service;
  
  if (defined($hash->{READINGS}{presence}) and $hash->{READINGS}{presence}{VAL} ne "online") {
    readingsSingleUpdate($hash,"presence","online",1);
  }
  
  DLNAClient_updateVolume($hash);
  
  Log3 $hash, 4, "DLNAClient: Using device \"".$hash->{helper}{device}->getfriendlyname()."\".";
  
  return undef;
}

sub
DLNAClient_updateVolume($)
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
DLNAClient_setAVTransport($)
{
  my ($string) = @_;
  my ($name, $streamURI) = split("\\|", $string);
  my $hash = $main::defs{$name};
  my $return = "$name|$streamURI";

  #streamURI received
  Log3 $hash, 4, "DLNAClient: start play for ".$streamURI;
  my $renderer = Net::UPnP::AV::MediaRenderer->new();
  $renderer->setdevice($hash->{helper}{device});

  Log3 $hash, 5, "DLNAClient: setAVTransportURI Start";
  $renderer->setAVTransportURI(CurrentURI => $streamURI);
  Log3 $hash, 5, "DLNAClient: setAVTransportURI End";
  $renderer->play();
  Log3 $hash, 5, "DLNAClient: play started";

  return $return;
}

###################################
sub
DLNAClient_finishedSetAVTransport($)
{
  my ($string) = @_;
  my @params = split("\\|", $string);
  my $name = $params[0];
  my $hash = $defs{$name};
  
  readingsSingleUpdate($hash,"stream",$params[1],1);
  readingsSingleUpdate($hash,"state","on",1);
  
  return undef;
}

###################################
sub
DLNAClient_Define($$)
{
  my ($hash, $def) = @_;
  my @param = split("[ \t][ \t]*", $def);
  
  return "too few parameters: define <name> DLNAClient <DLNAName>" if(int(@param) < 3);
  
  my $name            = shift @param;
  my $type            = shift @param;
  my $clientName      = join(" ", @param);
  $hash->{DEVNAME} = $clientName;
  
  Log3 $hash, 3, "DLNAClient: DLNA Client v1.23";
  
  readingsSingleUpdate($hash,"presence","offline",1);
  readingsSingleUpdate($hash,"state","initialized",1);
  
  InternalTimer(gettimeofday() + 10, 'DLNAClient_startUPnPScan', $hash, 0);
  
  return undef;
}

###################################
sub
DLNAClient_Undef($)
{
  my ($hash) = @_;
  
  #stop blocking call
  BlockingKill($hash->{helper}{SCAN_PID}) if(defined($hash->{helper}{SCAN_PID}));
  
  RemoveInternalTimer($hash);
  return undef;
}
###################################
sub
DLNAClient_Set($@)
{
  my ($hash, @param) = @_;
  my $deviceName = $hash->{DEVNAME};
  my $dev = $hash->{helper}{device};
  my $render_service = $hash->{helper}{render_service};
  my $streamURI = "";
  
  # check parameters
  return "no set value specified" if(int(@param) < 1);
  my $ctrlParam = $param[1];
  
  if ($ctrlParam eq "?" || (($ctrlParam eq "volume" || $ctrlParam eq "stream") && int(@param) < 3)) {
    return "Unknown argument, choose one of on:noArg off:noArg play:noArg stop:noArg stream volume:slider,0,1,100";
  }
    
  # check device presence
  if (!defined($dev) or $hash->{READINGS}{presence}{VAL} eq "offline") {
    return "DLNAClient: Currently searching for device $hash->{DEVNAME}...";
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
  if (!$streamURI && $ctrlParam eq "stream") {
    $streamURI = $param[2];
  }

  readingsSingleUpdate($hash, "state", "buffering", 1);
  BlockingCall('DLNAClient_setAVTransport', $hash->{NAME}."|".$streamURI, 'DLNAClient_finishedSetAVTransport');
  
  return undef;
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
