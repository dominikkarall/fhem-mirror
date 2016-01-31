#############################################################
#
# BOSEST.pm (c) by Dominik Karall, 2016
# dominik karall at gmail dot com
#
# FHEM module to communicate with BOSE SoundTouch system
# API as defined in BOSE SoundTouchAPI_WebServices_v1.0.1.pdf
#
# Version: 0.9.4
#
#############################################################
#
# v0.9.4 - 20160131
#  - use BlockingCall instead of ithreads
#
# v0.9.3 - 20160125
#  - fix "EV does not work with ithreads."
#
# v0.9.2 - 20160123
#  - fix memory leak
#  - use select instead of usleep
#
# v0.9.1 - 20160122
#  - bugfix for on/off support
#
# v0.9 - 20160121
#  - autodiscover BOSE SoundTouch players
#  - add alias for newly created devices
#  - update IP if the player IP changes
#  - automatically re-connect websocket
#  - support UTF-8 names with umlauts
#  - reconnect websocket when connection closed
#  - add firmware version & IP readings
#  - automatically update /info on IP update
#  - state: offline,playing,stopped,paused,online (online means standby)
#  - support on/off commands based on current state
#  - support more readings for now_playing
#
# v0.2 - 20160110
#  - support stop/play/pause/power
#  - change preset to channel according to DevGuidelinesAV
#  - read /info on startup
#  - connect to websocket to receive speaker events
#
# v0.1 - 20160105
#  - define BOSE Soundtouch based on fixed IP
#  - change volume via /volume
#  - change preset via /key
#
# TODO
#  - support setExtension on-for-timer, ...
#  - use BlockingCall instead of threads
#  - use frame ping to keep connection alive
#  - implement preset change updates
#  - check presence status based on websocket connection
#  - use less threads to reduce memory usage
#  - TEST: delete arguments and readings for main BOSEST
#  - implement all update msgs from websocket
#  - add attribute to ignore deviceID in main
#  - define own presets with attr
#  - "auto-zone" if 2 or more speakers play the same station
#  - support multi-room
#  - support "zone-buttons"
#  - support "double-tap" presets
#
#############################################################

package main;

use strict;
use warnings;

use LWP::UserAgent;
use XML::Simple;
use Data::Dumper;
use Net::Bonjour;
use Encode;

############ WEBSOCKET #############

package BOSEST_WebSocket;
use IO::Select;
use IO::Socket;

BEGIN {
    $ENV{MOJO_REACTOR} = "Mojo::Reactor::Poll";
}

use Mojo::UserAgent;
use XML::Simple;

sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;
    
    $self->{ip} = shift;
    $self->{deviceID} = shift;
    
    return $self;
}

sub startServer() {
    my ($self) = shift;
    $self->{socket} = new IO::Socket (
        LocalHost => '127.0.0.1',
        LocalPort => '404040',
        Proto => 'tcp',
        Listen => 5,
        Reuse => 1
    );
    $self->{read_set} = new IO::Select();
    $self->{read_set}->add($socket);
}

sub connect() {
    my $self = shift;
    my $exit = 0;
    my $ua = Mojo::UserAgent->new();
    $self->{requestId} = 1;
    my $ws = $ua->websocket('ws://'.$self->{ip}.':8080' => ['gabbo'] => sub { $self->_callback(@_) });
    $ua->inactivity_timeout(20);
    $ua->request_timeout(5);

    while (!$exit) {
        Mojo::IOLoop->one_tick;
        
        #check if there is something to receive
        my ($rh_set) = IO::Select->select($self->{read_set}, undef, undef, 0);
        foreach my $rh (@$rh_set) {
            if($rh == $self->{socket}) {
                $ns = $rh->accept();
                $self->{read_set}->add($ns);
            } else {
                my $buf = <$rh>;
                if($buf) {
                    #TODO process $buf
                } else {
                    $self->{read_set}->remove($rh);
                    close($rh);
                }
            }
        }
    }
}

sub send($) {
    my ($self, $msg) = @_;
    $self->{requestId}++;
    $self->{websocketTx}->send($msg);
}

sub _callback($$) {
    my ($self, $ua, $tx) = @_;
    $self->{websocketTx} = $tx;
    $tx->on(message => sub { $self->_receivedMessage(@_) });
    $tx->on(finish => sub { $self->_connectionClosed(@_) });
    Mojo::IOLoop->recurring(19 => sub { $self->_ping });
}

sub _receivedMessage($$) {
    my ($self, $tx, $msg) = @_;
    my $xml = XMLin($msg, KeepRoot => 1, ForceArray => 0, KeyAttr => []);
    $self->{websocketReceiverQueue}->enqueue($xml);
    #FIXME send xml using socket
    $self->{socket}->send($xml);
    shutdown($socket, 1);
    $tx->resume;
}

sub _connectionClosed($$$) {
    my ($self, $ws, $code, $reason) = @_;
    Mojo::IOLoop->stop;
}

sub _ping() {
    my $self = shift;
    $self->{requestId}++;
    if($self->{requestId} > 9999) {
        $self->{requestId} = 1;
    }
    $self->{websocketTx}->send('<msg><header deviceID="'.$self->{deviceID}.'
        " url="webserver/pingRequest" method="GET"><request requestID="'.$self->{requestId}.
        '"><info type="new"/></request></header></msg>');
}

############ MAIN #############

package main;

sub BOSEST_Discovery($) {
    my ($string) = @_;
    my ($name, $hash) = split("\\|", $string);
    my $return = "$name";
    
    my $res = Net::Bonjour->new('soundtouch');
    $res->discover;
    my @foundDevices = ();
    foreach my $device ($res->entries) {
        my $info = BOSEST_HTTPGET($hash, $device->address, "/info");
        next if (!defined($info->{deviceID}));
        push(@foundDevices, $info->{deviceID});
            
        #create new device
        if(!defiend($defs{"BOSE_$info->{deviceID}"}) {
            $info->{name} = Encode::encode('UTF-8',$info->{name});
            Log3 $hash, 3, "BOSEST: Device $info->{name} ($info->{deviceID}) found.";
            $return = $return."|commandDefineBOSE|$info->{deviceID},$info->{name}";
        }
            
        #update IP address of the device if it's different to the previous one
        $return = $return."|updateIP|$info->{deviceID},$device->address";
    }
    return $return;
}

sub BOSEST_finishedDiscovery($) {
    my ($string) = @_;
    my @commands = split("\\|", $string);
    my $name = $commands[0];
    my $hash = $defs{$name};
    my $i = 0;

    for($i = 1; $i < @commands; $i = $i+2) {
        my $command = $commands[$i];
        my @params = split(",", $commands[$i+1]);
        if($command eq "commandDefineBOSE") {
            my $deviceID = $params[0];
            my $deviceName = $params[1];
            BOSEST_commandDefine($hash, $deviceID, $deviceName);
        } elsif($command eq "updateIP") {
            my $deviceID = $params[0];
            my $ip = $params[1];
            BOSEST_updateIP($hash, $deviceID, $ip);
        }
    }
}

sub BOSEST_updateInfo($$) {
    my ($hash, $deviceID) = @_;
    #FIXME use BlockingCall for BOSEST_HTTPGET
    my $info = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/info");
    BOSEST_parseAndUpdateInfo($hash, $info);
    return undef;
}

sub BOSEST_parseAndUpdateInfo($$) {
    my ($hash, $info) = @_;
    readingsSingleUpdate($hash, $info->{deviceID}, "deviceName", $info->{name}, 1);
    readingsSingleUpdate($hash, $info->{deviceID}, "type", $info->{type}, 1);
    readingsSingleUpdate($hash, $info->{deviceID}, "deviceID", $info->{deviceID}, 1);
    readingsSingleUpdate($hash, $info->{deviceID}, "softwareVersion", $info->{components}->{component}[0]->{softwareVersion}, 1);
    return undef;
}

sub BOSEST_updateNowPlaying($$) {
    my ($hash, $deviceID) = @_;
    my $nowPlaying = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/now_playing");
    BOSEST_parseAndUpdateNowPlaying($hash, $nowPlaying);
    return undef;
}

sub BOSEST_parseAndUpdateNowPlaying($$) {
    my ($hash, $nowPlaying) = @_;
    BOSEST_XMLUpdate($hash, "stationName", $nowPlaying->{stationName});
    BOSEST_XMLUpdate($hash, "track", $nowPlaying->{track});
    BOSEST_XMLUpdate($hash, "source", $nowPlaying->{source});
    BOSEST_XMLUpdate($hash, "album", $nowPlaying->{album});
    BOSEST_XMLUpdate($hash, "artist", $nowPlaying->{artist});
    BOSEST_XMLUpdate($hash, "playStatus", $nowPlaying->{playStatus});
    BOSEST_XMLUpdate($hash, "stationLocation", $nowPlaying->{stationLocation});
    #description could be very long, therefore skip it for readings
    #BOSEST_XMLUpdate($hash, "description", $nowPlaying->{description});
    if($nowPlaying->{art}) {
        BOSEST_XMLUpdate($hash, "art", $nowPlaying->{art}->{content});
        BOSEST_XMLUpdate($hash, "artStatus", $nowPlaying->{art}->{artImageStatus});
    } else {
        BOSEST_XMLUpdate($hash, "art", "");
        BOSEST_XMLUpdate($hash, "artStatus", "");
    }
    if($nowPlaying->{ContentItem}) {
        BOSEST_XMLUpdate($hash, "contentItemItemName", $nowPlaying->{ContentItem}->{itemName});
        BOSEST_XMLUpdate($hash, "contentItemLocation", $nowPlaying->{ContentItem}->{location});
        BOSEST_XMLUpdate($hash, "contentItemSourceAccount", $nowPlaying->{ContentItem}->{sourceAccount});
        BOSEST_XMLUpdate($hash, "contentItemSource", $nowPlaying->{ContentItem}->{source});
        BOSEST_XMLUpdate($hash, "contentItemIsPresetable", $nowPlaying->{ContentItem}->{isPresetable});
    } else {
        BOSEST_XMLUpdate($hash, "contentItemItemName", "");
        BOSEST_XMLUpdate($hash, "contentItemLocation", "");
        BOSEST_XMLUpdate($hash, "contentItemSourceAccount", "");
        BOSEST_XMLUpdate($hash, "contentItemSource", "");
        BOSEST_XMLUpdate($hash, "contentItemIsPresetable", "");
    }
    #handle state based on play status and standby state
    if($nowPlaying->{source} eq "STANDBY") {
        BOSEST_XMLUpdate($hash, "state", "online");
    } else {
        if($nowPlaying->{playStatus} eq "BUFFERING_STATE") {
            BOSEST_XMLUpdate($hash, "state", "buffering");
        } elsif($nowPlaying->{playStatus} eq "PLAY_STATE") {
            BOSEST_XMLUpdate($hash, "state", "playing");
        } elsif($nowPlaying->{playStatus} eq "STOP_STATE") {
            BOSEST_XMLUpdate($hash, "state", "stopped");
        } elsif($nowPlaying->{playStatus} eq "PAUSE_STATE") {
            BOSEST_XMLUpdate($hash, "state", "paused");
        } elsif($nowPlaying->{playStatus} eq "INVALID_PLAY_STATUS") {
            BOSEST_XMLUpdate($hash, "state", "invalid");
        }
    }
    
    return undef;
}

sub BOSEST_updateIP($$$) {
    my ($hash, $deviceID, $ip) = @_;
    my $deviceHash = BOSEST_getBosePlayerByDeviceID($hash, $deviceID);
    #check current IP of the device
    my $currentIP = $deviceHash->{helper}{IP};
    $currentIP = "unknown" if(!defined($currentIP));

    #if update is needed, get info/now_playing
    if($currentIP ne $ip) {
        $deviceHash->{helper}{IP} = $ip;
        readingsSingleUpdate($deviceHash, "IP", $ip, 1);
        #get info
        BOSEST_updateInfo($deviceHash, $deviceID);
        #get now_playing
        BOSEST_updateNowPlaying($deviceHash, $deviceID);
        #connect websocket
        if(!defined($deviceHash->{helper}{WEBSOCKET_PID})) {
            $deviceHash->{helper}{WEBSOCKET_PID} = BlockingCall("BOSEST_WebSocket", "$deviceHash->{NAME}|$deviceID");
        }
    }
    return undef;
}

sub BOSEST_commandDefine($$$) {
    my ($hash, $deviceID, $deviceName) = @_;
    #check if device exists already
    if(!defined(BOSEST_getBosePlayerByDeviceID($hash, $deviceID))) {
        CommandDefine(undef, "BOSE_$deviceID BOSEST $deviceID");
        CommandAttr(undef, "BOSE_$deviceID alias $deviceName");
    }
    return undef;
}

sub BOSEST_getBosePlayerByDeviceID($$) {
    my ($hash, $deviceID) = @_;
    my $deviceName = "BOSE_".$deviceID;

    return $main::defs{$deviceName};
}

sub BOSEST_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn} = 'BOSEST_Define';
    $hash->{UndefFn} = 'BOSEST_Undef';
    $hash->{GetFn} = 'BOSEST_Get';
    $hash->{SetFn} = 'BOSEST_Set';
    
    return undef;
}

sub BOSEST_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t]+", $def);
    my $name;
    
    $hash->{DEVICEID} = "0";
    $hash->{STATE} = "initialized";
    
    if (int(@a) > 3) {
        return 'BOSEST: Wrong syntax, must be define <name> BOSEST [<deviceID>]';
    } elsif(int(@a) == 3) {
        $name = $a[0];
        $hash->{DEVICEID} = $a[2];
        readingsSingleUpdate($hash, "IP", "unknown", 1);
    }
    
    if (int(@a) < 3) {
        #start discovery thread
        #wait with InternalTimer and start Discovery after 5s (repeat every 60s)
        if (!defined($hash->{helper}{DISCOVERY_PID})) {
            $hash->{helper}{DISCOVERY_PID} = BlockingCall("BOSEST_Discovery", $hash->{NAME}."|".$hash, "BOSEST_finishedDiscovery");
        }
    }
    
    return undef;
}

sub BOSEST_Set($@) {
    my ($hash, @params) = @_;
    my $name = shift(@params);
    my $workType = shift(@params);

    Log3 $hash, 5, "BOSEST: ".$data{WorkType}.", deviceID: ".$data{DeviceID}.", IP: ".ReadingsVal($hash->{NAME}, "IP", "unknown");
    
    # check parameters for set function
    #DEVELOPNEWFUNCTION-1
    if($workType eq "?") {
        if($hash->{DEVICEID} eq "0") {
            return ""; #no arguments for server
        } else {
            return "Unknown argument, choose one of on off power:noArg play:noArg 
                    stop:noArg pause:noArg channel:1,2,3,4,5,6 volume:slider,0,1,100";
        }
    } elsif($workType eq "volume") {
        return "BOSEST: volume requires volume as additional parameter" if(int(@params) < 1);
    } elsif($data{WorkType} eq "channel") {
        return "BOSEST: channel requires preset id as additional parameter" if(int(@params) < 1);
    } elsif($data{WorkType} eq "play") {
        #no additional parameters needed
    } elsif($data{WorkType} eq "stop") {
        #no additional parameters needed
    } elsif($data{WorkType} eq "pause") {
        #no additional parameters needed
    } elsif($data{WorkType} eq "power") {
        #no additional parameters needed
    } elsif($data{WorkType} eq "on") {
        push(@params, ReadingsVal($hash->{NAME}, "source", "STANDBY"));
    } elsif($data{WorkType} eq "off") {
        push(@params, ReadingsVal($hash->{NAME}, "source", "STANDBY"));
    } else {
        return "BOSEST: Unknown argument $data{WorkType}";
    }

    $hash->{helper}{SETBLOCKING_PID} = BlockingCall();
    
    push(@params, ReadingsVal($hash->{NAME}, "IP", "unknown"));
    $data{Params} = \@params;
    #FIXME call blocking call
    
    return undef;
}

sub BOSEST_WebSocketClient($) {
    my ($hash) = @_;
    my $exit = 0;
    
    my $socket = new IO::Socket (
        PeerHost => $hash->{helper}{IP},
        PeerPort => '404040',
        Proto => 'tcp'
    );
    
    #connect to server and check for input (recv)
    while(!$exit) {
        my $msg = "";
        $socket->recv($msg, 1024);
        #process received message
        Log3 $hash, 3, "BOSEST: Received from WebSocket:\n$msg";

        #check worktype and call worktype specific function
        #DEVELOPNEWFUNCTION-2
        if($workType eq "volume") {
            my $volume = $params[0];
            BOSEST_setVolume($deviceHash, $volume);
        } elsif($workType eq "channel") {
            my $preset = $params[0];
            #FIXME check preset value (1-6)
            BOSEST_setPreset($deviceHash, $preset);
        } elsif($workType eq "play") {
            BOSEST_play($deviceHash);
        } elsif($workType eq "stop") {
            BOSEST_stop($deviceHash);
        } elsif($workType eq "pause") {
            BOSEST_pause($deviceHash);
        } elsif($workType eq "power") {
            BOSEST_power($deviceHash);
        } elsif($workType eq "on") {
            my $sourceState = $params[0];
            BOSEST_on($deviceHash, $sourceState);
        } elsif($workType eq "off") {
            my $sourceState = $params[0];
            BOSEST_off($deviceHash, $sourceState);
        }
    }
}

#DEVELOPNEWFUNCTION-3 (create own function)
sub BOSEST_on($$) {
    my ($hash, $sourceState) = @_;
    if($sourceState eq "STANDBY") {
        BOSEST_power($hash);
    }
}

sub BOSEST_off($$) {
    my ($hash, $sourceState) = @_;
    if($sourceState ne "STANDBY") {
        BOSEST_power($hash);
    }
}

sub BOSEST_setVolume($$) {
    my ($hash, $volume) = @_;
    my $postXml = '<volume>'.$volume.'</volume>';
    if(BOSEST_HTTPPOST($hash, '/volume', $postXml) == 0) {
        BOSEST_readingsSingleUpdate($hash, $hash->{DEVICEID}, "volume", $volume);
    }
    #FIXME error handling
    return undef;
}

sub BOSEST_setPreset($$) {
    my ($hash, $preset) = @_;
    BOSEST_sendKey($hash, "PRESET_".$preset);
    BOSEST_readingsSingleUpdate($hash, $hash->{DEVICEID}, "channel", $preset);
    return undef;
}

sub BOSEST_play($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "PLAY");
    BOSEST_readingsSingleUpdate($hash, $hash->{DEVICEID}, "playStatus", "playing");
    return undef;
}

sub BOSEST_stop($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "STOP");
    BOSEST_readingsSingleUpdate($hash, $hash->{DEVICEID}, "playStatus", "stopped");
    return undef;
}

sub BOSEST_pause($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "PAUSE");
    BOSEST_readingsSingleUpdate($hash, $hash->{DEVICEID}, "playStatus", "paused");
    return undef;
}

sub BOSEST_power($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "POWER");
    return undef;
}

sub BOSEST_Undef($) {
    my $hash = @_;
    return undef;
}

sub BOSEST_Get($$) {
    return undef;
}

# generic functions
sub BOSEST_sendKey($$) {
    my ($hash, $key) = @_;
    my $postXml = '<key state="press" sender="Gabbo">'.$key.'</key>';
    if(BOSEST_HTTPPOST($hash, '/key', $postXml) == 0) {
        select(undef, undef, undef, .1); #sleep 100ms
        $postXml = '<key state="release" sender="Gabbo">'.$key.'</key>';
        if(BOSEST_HTTPPOST($hash, '/key', $postXml) == 0) {
            #FIXME success
        }
    }
    #FIXME error handling
    return undef;
}

sub BOSEST_HTTPGET($$$) {
    my ($hash, $ip, $getURI) = @_;
    my $ua = LWP::UserAgent->new();
    my $req = HTTP::Request->new(GET => 'http://'.$ip.':8090'.$getURI);
    my $response = $ua->request($req);
    if($response->is_success) {
        my $xmlres = XMLin($response->decoded_content, ForceArray => 0, KeyAttr => []);
        return $xmlres;
    } else {
        #TODO return error
    }

    return undef;
}

sub BOSEST_HTTPPOST($$$) {
    my ($hash, $postURI, $postXml) = @_;
    my $ua = LWP::UserAgent->new();
    my $ip = $hash->{IP};
    my $req = HTTP::Request->new(POST => 'http://'.$ip.':8090'.$postURI);
    Log3 $hash, 5, "BOSEST: set ".$postURI." => ".$postXml;
    $req->content($postXml);

    my $response = $ua->request($req);
    if($response->is_success) {
        Log3 $hash, 5, "BOSEST: success: ".$response->decoded_content;
        return 0;
    } else {
        #TODO return error
        Log3 $hash, 3, "BOSEST: failed: ".$response->status_line;
        return 1;
    }
    
    return 1;
}

sub BOSEST_XMLUpdate($$$) {
    my ($hash, $readingName, $xmlItem) = @_;

    if(ref $xmlItem eq ref {}) {
        if(keys %{$xmlItem}) {
            readingsSingleUpdate($hash, $readingName, $xmlItem, 1);
        } else {
            readingsSingleUpdate($hash, $readingName, "", 1);
        }
    } elsif($xmlItem) {
        readingsSingleUpdate($hash, $readingName, $xmlItem, 1);
    } else {
        readingsSingleUpdate($hash, $readingName, "", 1);
    }
    return undef;
}

sub BOSEST_Check($) {
    my ($hash) = @_;
    my $maxupdates = 5;
    my $updates = 0;

    while($hash->{WebSocketReceiverQueue}->pending() && $updates < $maxupdates) {
    	my $wsxml = $hash->{WebSocketReceiverQueue}->dequeue_nb();
        $updates++;
        if($wsxml->{updates}) {
            if($wsxml->{updates}->{nowPlayingUpdated}) {
                if($wsxml->{updates}->{nowPlayingUpdated}->{nowPlaying}) {
                    BOSEST_parseAndUpdateNowPlaying($hash, $wsxml->{updates}->{nowPlayingUpdated}->{nowPlaying});
                }
            } elsif ($wsxml->{updates}->{volumeUpdated}) {
                my $volumeUpdated = $wsxml->{updates}->{volumeUpdated};
                BOSEST_XMLUpdate($hash, "volume", $volumeUpdated->{volume}->{actualvolume});
            } elsif ($wsxml->{updates}->{nowSelectionUpdated}) {
                #Log3 $hash, 3, "BOSEST: Event not implemented (nowSelectionUpdated):\n".Dumper($wsxml);
                #TODO implement now selection updated event
            } elsif ($wsxml->{updates}->{recentsUpdated}) {
                #Log3 $hash, 3, "BOSEST: Event not implemented (recentsUpdated):\n".Dumper($wsxml);
                #TODO implement recent channel event
            } elsif ($wsxml->{updates}->{connectionStateUpdated}) {
                #BOSE SoundTouch team says that it's not necessary to handle this one
            } else {
                Log3 $hash, 3, "BOSEST: Unknown event, please implement:\n".Dumper($wsxml);
            }
        }
    }

    $updates = 0;
                if(defined($deviceHash->{WebSocket})) {
                    $deviceHash->{WebSocketInputQueue}->enqueue($params[0]);
                    Log3 $hash, 3, "BOSEST: Update IP $params[0] for BOSE_$deviceID";
                } else {
                    $deviceHash->{WebSocket} = BOSEST_WebSocket->new($params[0], $deviceHash->{WebSocketReceiverQueue}, $deviceID, $deviceHash->{WebSocketInputQueue});
                    Log3 $hash, 3, "BOSEST: New IP ".$params[0]." for BOSE_$deviceID";
                }
            }
        }
    }
    
    InternalTimer(gettimeofday()+1, "BOSEST_Check", $hash, 1);
    
    return undef;
}

1;

=pod
=begin html

<a name="BOSEST"></a>
<h3>BOSEST</h3>
<ul>

  BOSE SoundTouch system interface</a>.
  
  <br><br>

  <a name="BOSESTdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; BOSEST &lt;IP&gt;</code>
    <br><br>

    Example:
    <ul>
      <code>define bose_wz BOSEST 192.168.1.150</code><br>
      Defines BOSE SoundTouch with IP 192.168.1.150 named bose_wz.<br/>
    </ul>
  </ul>
  <br>

  <a name="BOSESTset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; volume &lt;value&gt</code><br>
    Set volume.
  </ul>
  <ul>
    <code>set &lt;name&gt; &lt;channel&gt 1-6</code><br>
    Set preset to play.
  </ul>
  <br>

</ul>

=end html
=cut

