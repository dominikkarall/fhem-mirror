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

use Net::UPnP::ControlPoint;
use Net::UPnP::Device;
use Net::UPnP::AV::MediaRenderer;

my %DLNAClient_deviceList = {};

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
  
  my $obj = Net::UPnP::ControlPoint->new();
  my @dev_list = $obj->search(st =>'urn:schemas-upnp-org:device:MediaRenderer:1', mx => 3);
  
  foreach my $dev (@dev_list) {
    Log3 $hash, 3, "DLNAClient: Found device ".$dev->getfriendlyname();
    push(@($DLNAClient_deviceList->{$name}{devices}), $dev);
    #$return = $return."|".$dev->getssdp()."|".$dev->getdescription();
  }
  
  Log3 $hash, 3, "DLNAClient: Return from search: $return";
  
  return $return;
}

sub
DLNAClient_finishedUPnPScan($)
{
  my ($name) = @_;
  my $hash = $defs{$name};

  delete($hash->{helper}{SCAN_PID});
  
  foreach my $dev (@($DLNAClient_deviceList->{$name}{devices})) {
    Log3 $hash, 3, "DLNAClient: Finished Search, found device ".$dev->getfriendlyname();
    
    if($dev->getfriendlyname() eq $hash->{DEVNAME}) {
      #set device
      $hash->{helper}{device} = $dev;
      Log3 $hash, 3, "DLNAClient: Found device \"".$dev->getfriendlyname()."\".";
    }
  }

  InternalTimer(gettimeofday() + 60, 'DLNAClient_startUPnPScan', $hash, 0);
  
  return undef;
}

###################################
sub
DLNAClient_setAVTransport($)
{
  my ($string) = @_;
  my ($name, $hash, $streamURI) = split("|", $string);
  my $return = "$name|$streamURI";

  #streamURI received
  Log3 $hash, 5, "DLNAClient: start play for ".$streamURI;
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
  my $streamURI = "";
  
  # check parameters
  return "no set value specified" if(int(@param) < 1);
  my $ctrlParam = $param[1];
  
  if ($ctrlParam eq "?" || (($ctrlParam eq "volume" || $ctrlParam eq "stream") && int(@param) < 3)) {
    return "Unknown argument, choose one of on:noArg off:noArg play:noArg stop:noArg stream volume:slider,0,1,100";
  }
    
  # check device presence
  if (!defined($dev)) {
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
  if (!$streamURI && $ctrlParam eq "stream") {
    $streamURI = $param[2];
  }

  readingsSingleUpdate($hash, "state", "buffering", 1);
  BlockingCall('DLNAClient_setAVTransport', $hash->{NAME}."|".$hash."|".$streamURI, 'DLNAClient_finishedSetAVTransport');
  
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
