#############################################################
#
# BOSEST.pm (c) by Dominik Karall, 2016
# dominik karall at gmail dot com
#
# FHEM module to communicate with BOSE SoundTouch system
# API as defined in BOSE SoundTouchAPI_WebServices_v1.0.1.pdf
#
# Version: 0.9.7
#
#############################################################
#
# v0.9.7 - 20160214
#  - FEATURE: print module version on startup of main module
#  - FEATURE: support device rename (e.g. BOSE_... => wz_BOSE)
#  - FEATURE: show preset itemNames in channel_X reading
#  - FEATURE: automatically update preset readings on change
#  - FEATURE: add description reading (could be very long)
#  - CHANGE: change log level for not implemented events to 4
#  - CHANGE: use only one processXml function for websocket and http
#  - BUGFIX: fix set off/on more than once within 1 second
#  - BUGFIX: fix warnings during setup process
#  - BUGFIX: support umlauts in all readings
#  - BUGFIX: handle XMLin errors with eval
#  - BUGFIX: handle "set" when speaker wasn't found yet
#
# v0.9.6 - 20160210
#  - FEATURE: support prev/next track
#
# v0.9.5 - 20160210
#  - FEATURE: update channel based on websocket events
#  - BUGFIX: specify minimum libmojolicious-perl version
#  - BUGFIX: reconnect websocket if handshake fails
#  - BUGFIX: presence reading fixed
#  - CHANGE: websocket request timeout changed to 10s (prev. 5s)
#  - CHANGE: clockDisplayUpdated message handled now
#
# v0.9.4 - 20160206
#  - CHANGE: completely drop ithreads (reduces memory usage)
#  - CHANGE: search for new devices every 60s (BlockingCall)
#  - CHANGE: check presence status based on websocket connection
#  - BUGFIX: removed arguments and readings for main BOSEST
#  - FEATURE: read volume on startup
#
# v0.9.3 - 20160125
#  - BUGFIX: fix "EV does not work with ithreads."
#
# v0.9.2 - 20160123
#  - BUGFIX: fix memory leak
#  - BUGFIX: use select instead of usleep
#
# v0.9.1 - 20160122
#  - BUGFIX: bugfix for on/off support
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
#  - update readings only on change
#  - check if websocket finished can be called after websocket re-connected
#  - cleanup all readings on startup (IP=unknown)
#  - use LWP callback functions
#  - support multi-room (play everywhere)
#  - support recents list (set recent...)
#  - fix usage of bulkupdate vs. singleupdate
#  - check if Mojolicious::Lite can be used
#  - support setExtension on-for-timer, ...
#  - use frame ping to keep connection alive
#  - add attribute to ignore deviceID in main
#  - define own presets with attr (7:1234,8:4567,...)
#  - "auto-zone" if 2 or more speakers play the same station
#  - support "zone-buttons"
#  - support "double-tap" presets
#  - support bass settings
#
#############################################################


BEGIN {
    $ENV{MOJO_REACTOR} = "Mojo::Reactor::Poll";
}

package main;

use strict;
use warnings;

use Blocking;
use Encode;

use Data::Dumper;
use LWP::UserAgent;
use Mojolicious 5.54;
use Net::Bonjour;
use XML::Simple;

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
        #set device id from parameter
        $hash->{DEVICEID} = $a[2];
        #set IP to unknown
        $hash->{helper}{IP} = "unknown";
        readingsSingleUpdate($hash, "IP", "unknown", 1);
        
        #TODO cleanup all readings on startup
        
        #allow on/off commands
        $hash->{helper}{sent_on} = 0;
        $hash->{helper}{sent_off} = 0;
    }
    
    if (int(@a) < 3) {
        Log3 $hash, 3, "BOSEST: BOSE SoundTouch v0.9.7";
        #start discovery process 30s delayed
        InternalTimer(gettimeofday()+30, "BOSEST_startDiscoveryProcess", $hash, 0);
    }
    
    return undef;
}

sub BOSEST_Set($@) {
    my ($hash, @params) = @_;
    my $name = shift(@params);
    my $workType = shift(@params);

    # check parameters for set function
    #DEVELOPNEWFUNCTION-1
    if($workType eq "?") {
        if($hash->{DEVICEID} eq "0") {
            return ""; #no arguments for server
        } else {
            return "Unknown argument, choose one of on:noArg off:noArg power:noArg play:noArg 
                    nextTrack:noArg prevTrack:noArg
                    stop:noArg pause:noArg channel:1,2,3,4,5,6 volume:slider,0,1,100";
        }
    }
    
    if($hash->{helper}{IP} eq "unknown") {
        return "Searching for BOSE SoundTouch, try again later...";
    }
    
    if($workType eq "volume") {
        return "BOSEST: volume requires volume as additional parameter" if(int(@params) < 1);
        #params[0] = volume value
        BOSEST_setVolume($hash, $params[0]);
    } elsif($workType eq "channel") {
        return "BOSEST: channel requires preset id as additional parameter" if(int(@params) < 1);
        #params[0] = preset channel
        BOSEST_setPreset($hash, $params[0]);
    } elsif($workType eq "play") {
        BOSEST_play($hash);
    } elsif($workType eq "stop") {
        BOSEST_stop($hash);
    } elsif($workType eq "pause") {
        BOSEST_pause($hash);
    } elsif($workType eq "power") {
        BOSEST_power($hash);
    } elsif($workType eq "on") {
        if(!$hash->{helper}{sent_on}) {
            BOSEST_on($hash);
            $hash->{helper}{sent_on} = 1;
        }
    } elsif($workType eq "off") {
        if(!$hash->{helper}{sent_off}) {
            BOSEST_off($hash);
            $hash->{helper}{sent_off} = 1;
        }
    } elsif($workType eq "nextTrack") {
        BOSEST_next($hash);
    } elsif($workType eq "prevTrack") {
        BOSEST_prev($hash);
    } else {
        return "BOSEST: Unknown argument $workType";
    }
    
    return undef;
}

#DEVELOPNEWFUNCTION-2 (create own function)
sub BOSEST_on($) {
    my ($hash) = @_;
    my $sourceState = ReadingsVal($hash->{NAME}, "source", "STANDBY");
    if($sourceState eq "STANDBY") {
        BOSEST_power($hash);
    }
}

sub BOSEST_off($) {
    my ($hash) = @_;
    my $sourceState = ReadingsVal($hash->{NAME}, "source", "STANDBY");
    if($sourceState ne "STANDBY") {
        BOSEST_power($hash);
    }
}

sub BOSEST_setVolume($$) {
    my ($hash, $volume) = @_;
    my $postXml = '<volume>'.$volume.'</volume>';
    if(BOSEST_HTTPPOST($hash, '/volume', $postXml) == 0) {
        readingsSingleUpdate($hash, "volume", $volume, 1);
    }
    #FIXME error handling
    return undef;
}

sub BOSEST_setPreset($$) {
    my ($hash, $preset) = @_;
    BOSEST_sendKey($hash, "PRESET_".$preset);
    readingsSingleUpdate($hash, "channel", $preset, 1);
    return undef;
}

sub BOSEST_play($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "PLAY");
    readingsSingleUpdate($hash, "playStatus", "playing", 1);
    return undef;
}

sub BOSEST_stop($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "STOP");
    readingsSingleUpdate($hash, "playStatus", "stopped", 1);
    return undef;
}

sub BOSEST_pause($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "PAUSE");
    readingsSingleUpdate($hash, "playStatus", "paused", 1);
    return undef;
}

sub BOSEST_power($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "POWER");
    return undef;
}

sub BOSEST_next($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "NEXT_TRACK");
    return undef;
}

sub BOSEST_prev($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "PREV_TRACK");
    return undef;
}

sub BOSEST_Undef($) {
    my ($hash) = @_;

    #remove internal timer
    RemoveInternalTimer($hash);

    #kill blocking
    BlockingKill($hash->{helper}{DISCOVERY_PID}) if(defined($hash->{helper}{DISCOVERY_PID}));
    BlockingKill($hash->{helper}{WEBSOCKET_PID}) if(defined($hash->{helper}{WEBSOCKET_PID}));
    
    return undef;
}

sub BOSEST_Get($$) {
    return undef;
}

###### UPDATE VIA HTTP ######
sub BOSEST_updateInfo($$) {
    my ($hash, $deviceId) = @_;
    my $info = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/info");
    BOSEST_processXml($hash, $info);
    return undef;
}


sub BOSEST_updatePresets($$) {
    my ($hash, $deviceId) = @_;
    my $presets = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/presets");
    BOSEST_processXml($hash, $presets);
    return undef;    
}

sub BOSEST_updateVolume($$) {
    my ($hash, $deviceId) = @_;
    my $volume = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/volume");
    BOSEST_processXml($hash, $volume);
    return undef;    
}

sub BOSEST_updateNowPlaying($$) {
    my ($hash, $deviceId) = @_;
    my $nowPlaying = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/now_playing");
    BOSEST_processXml($hash, $nowPlaying);
    return undef;
}

###### XML PROCESSING ######
sub BOSEST_processXml($$) {
    my ($hash, $wsxml) = @_;
    
    if($wsxml->{updates}) {
        if($wsxml->{updates}->{nowPlayingUpdated}) {
            if($wsxml->{updates}->{nowPlayingUpdated}->{nowPlaying}) {
                BOSEST_parseAndUpdateNowPlaying($hash, $wsxml->{updates}->{nowPlayingUpdated}->{nowPlaying});
            }
        } elsif ($wsxml->{updates}->{volumeUpdated}) {
            BOSEST_parseAndUpdateVolume($hash, $wsxml->{updates}->{volumeUpdated}->{volume});
        } elsif ($wsxml->{updates}->{nowSelectionUpdated}) {
            readingsBeginUpdate($hash);
            BOSEST_XMLUpdate($hash, "channel", $wsxml->{updates}->{nowSelectionUpdated}->{preset}->{id});
            readingsEndUpdate($hash, 1);
        } elsif ($wsxml->{updates}->{recentsUpdated}) {
            #Log3 $hash, 3, "BOSEST: Event not implemented (recentsUpdated):\n".Dumper($wsxml);
            #TODO implement recent channel event
        } elsif ($wsxml->{updates}->{connectionStateUpdated}) {
            #BOSE SoundTouch team says that it's not necessary to handle this one
        } elsif ($wsxml->{updates}->{clockDisplayUpdated}) {
            #TODO handle clockDisplayUpdated (feature currently unknown)
        } elsif ($wsxml->{updates}->{presetsUpdated}) {
            BOSEST_parseAndUpdatePresets($hash, $wsxml->{updates}->{presetsUpdated}->{presets});
        } else {
            Log3 $hash, 4, "BOSEST: Unknown event, please implement:\n".Dumper($wsxml);
        }
    } elsif($wsxml->{info}) {
        BOSEST_parseAndUpdateInfo($hash, $wsxml->{info});
    } elsif($wsxml->{nowPlaying}) {
        BOSEST_parseAndUpdateNowPlaying($hash, $wsxml->{nowPlaying});
    } elsif($wsxml->{volume}) {
        BOSEST_parseAndUpdateVolume($hash, $wsxml->{volume});
    } elsif($wsxml->{presets}) {
        BOSEST_parseAndUpdatePresets($hash, $wsxml->{presets});
    }
    
    return undef;
}

sub BOSEST_parseAndUpdatePresets($$) {
    my ($hash, $presets) = @_;
    my $maxpresets = 6;
    my %activePresets = ();
    
    readingsBeginUpdate($hash);
    foreach my $preset (1..6) {
        $activePresets{$preset} = "-";
    }
    
    foreach my $preset (@{ $presets->{preset} }) {
        $activePresets{$preset->{id}} = $preset->{ContentItem}->{itemName};
    }
    
    foreach my $preset (1..6) {
        BOSEST_XMLUpdate($hash, "channel_$preset", $activePresets{$preset});
    }
    
    readingsEndUpdate($hash, 1);
    return undef;
}

sub BOSEST_parseAndUpdateVolume($$) {
    my ($hash, $volume) = @_;
    readingsBeginUpdate($hash);
    BOSEST_XMLUpdate($hash, "volume", $volume->{actualvolume});
    readingsEndUpdate($hash, 1);
    return undef;
}

sub BOSEST_parseAndUpdateInfo($$) {
    my ($hash, $info) = @_;
    $info->{name} = Encode::encode('UTF-8', $info->{name});
    readingsSingleUpdate($hash, "deviceName", $info->{name}, 1);
    readingsSingleUpdate($hash, "type", $info->{type}, 1);
    readingsSingleUpdate($hash, "deviceID", $info->{deviceID}, 1);
    readingsSingleUpdate($hash, "softwareVersion", $info->{components}->{component}[0]->{softwareVersion}, 1);
    return undef;
}

sub BOSEST_parseAndUpdateNowPlaying($$) {
    my ($hash, $nowPlaying) = @_;
    Log3 $hash, 5, "BOSEST: parseAndUpdateNowPlaying";

    readingsBeginUpdate($hash);

    BOSEST_XMLUpdate($hash, "stationName", $nowPlaying->{stationName});
    BOSEST_XMLUpdate($hash, "track", $nowPlaying->{track});
    BOSEST_XMLUpdate($hash, "source", $nowPlaying->{source});
    BOSEST_XMLUpdate($hash, "album", $nowPlaying->{album});
    BOSEST_XMLUpdate($hash, "artist", $nowPlaying->{artist});
    BOSEST_XMLUpdate($hash, "playStatus", $nowPlaying->{playStatus});
    BOSEST_XMLUpdate($hash, "stationLocation", $nowPlaying->{stationLocation});
    BOSEST_XMLUpdate($hash, "trackID", $nowPlaying->{trackID});
    BOSEST_XMLUpdate($hash, "artistID", $nowPlaying->{artistID});
    BOSEST_XMLUpdate($hash, "rating", $nowPlaying->{rating});
    BOSEST_XMLUpdate($hash, "description", $nowPlaying->{description});
    if($nowPlaying->{time}) {
        BOSEST_XMLUpdate($hash, "time", $nowPlaying->{time}->{content});
        BOSEST_XMLUpdate($hash, "timeTotal", $nowPlaying->{time}->{total});
    } else {
        BOSEST_XMLUpdate($hash, "time", "");
        BOSEST_XMLUpdate($hash, "timeTotal", "");
    }
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
        BOSEST_XMLUpdate($hash, "contentItemType", $nowPlaying->{ContentItem}->{type});
    } else {
        BOSEST_XMLUpdate($hash, "contentItemItemName", "");
        BOSEST_XMLUpdate($hash, "contentItemLocation", "");
        BOSEST_XMLUpdate($hash, "contentItemSourceAccount", "");
        BOSEST_XMLUpdate($hash, "contentItemSource", "");
        BOSEST_XMLUpdate($hash, "contentItemIsPresetable", "");
        BOSEST_XMLUpdate($hash, "contentItemType", "");
    }
    #handle state based on play status and standby state
    if($nowPlaying->{source} eq "STANDBY") {
        BOSEST_XMLUpdate($hash, "state", "online");
    } else {
        if(defined($nowPlaying->{playStatus})) {
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
    }
    
    #reset sent_off/on to enable the command again
    #it's not allowed to send 2 times off/on due to toggle
    #therefore I'm waiting for one signal to be
    #received via websocket
    $hash->{helper}{sent_off} = 0;
    $hash->{helper}{sent_on} = 0;
    
    readingsEndUpdate($hash, 1);   
    
    return undef;
}

###### DISCOVERY #######
sub BOSEST_startDiscoveryProcess($) {
    my ($hash) = @_;
    
    if(!$init_done) {
        #init not done yet, wait 3 more seconds
        InternalTimer(gettimeofday()+3, "BOSEST_startDiscoveryProcess", $hash, 0);
    }
    
    if (!defined($hash->{helper}{DISCOVERY_PID})) {
        $hash->{helper}{DISCOVERY_PID} = BlockingCall("BOSEST_Discovery", $hash->{NAME}."|".$hash, "BOSEST_finishedDiscovery");
    }
}

sub BOSEST_Discovery($) {
    my ($string) = @_;
    my ($name, $hash) = split("\\|", $string);
    my $return = "$name";
    
    eval {
        my $res = Net::Bonjour->new('soundtouch');
        $res->discover;
        foreach my $device ($res->entries) {
            my $info = BOSEST_HTTPGET($hash, $device->address, "/info");
            #remove info tag to reduce line length
            $info = $info->{info} if (defined($info->{info}));
            #skip entry if no deviceid was found
            next if (!defined($info->{deviceID}));
            
            #create new device if it doesn't exist
            if(!defined(BOSEST_getBosePlayerByDeviceId($hash, $info->{deviceID}))) {
                $info->{name} = Encode::encode('UTF-8',$info->{name});
                Log3 $hash, 3, "BOSEST: Device $info->{name} ($info->{deviceID}) found.";
                $return = $return."|commandDefineBOSE|$info->{deviceID},$info->{name}";
            }
            
            #update IP address of the device
            $return = $return."|updateIP|".$info->{deviceID}.",".$device->address;
        }
    };

    if($@) {
        Log3 $hash, 3, "BOSEST: Discovery failed with: $@";
    }

    return $return;
}

sub BOSEST_finishedDiscovery($) {
    my ($string) = @_;
    my @commands = split("\\|", $string);
    my $name = $commands[0];
    my $hash = $defs{$name};
    my $i = 0;
    
    delete($hash->{helper}{DISCOVERY_PID});
    
    #start discovery again after 60s
    InternalTimer(gettimeofday()+60, "BOSEST_startDiscoveryProcess", $hash, 1);

    for($i = 1; $i < @commands; $i = $i+2) {
        my $command = $commands[$i];
        my @params = split(",", $commands[$i+1]);
        if($command eq "commandDefineBOSE") {
            my $deviceId = $params[0];
            my $deviceName = $params[1];
            BOSEST_commandDefine($hash, $deviceId, $deviceName);
        } elsif($command eq "updateIP") {
            my $deviceId = $params[0];
            my $ip = $params[1];
            BOSEST_updateIP($hash, $deviceId, $ip);
        }
    }
}

sub BOSEST_updateIP($$$) {
    my ($hash, $deviceID, $ip) = @_;
    my $deviceHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceID);
    #check current IP of the device
    my $currentIP = $deviceHash->{helper}{IP};
    $currentIP = "unknown" if(!defined($currentIP));

    #if update is needed, get info/now_playing
    if($currentIP ne $ip) {
        $deviceHash->{helper}{IP} = $ip;
        readingsSingleUpdate($deviceHash, "IP", $ip, 1);
        readingsSingleUpdate($deviceHash, "presence", "online", 1);
        Log3 $hash, 3, "BOSEST: $deviceHash->{NAME}, new IP ($ip)";
        #get info
        BOSEST_updateInfo($deviceHash, $deviceID);
        #get now_playing
        BOSEST_updateNowPlaying($deviceHash, $deviceID);
        #get current volume
        BOSEST_updateVolume($deviceHash, $deviceID);
        #get current presets
        BOSEST_updatePresets($deviceHash, $deviceID);
        #connect websocket
        Log3 $hash, 4, "BOSEST: $deviceHash->{NAME}, start new WebSocket.";
        BOSEST_startWebSocketConnection($deviceHash);
        BOSEST_checkWebSocketConnection($deviceHash);
    }
    return undef;
}

sub BOSEST_commandDefine($$$) {
    my ($hash, $deviceID, $deviceName) = @_;
    #check if device exists already
    if(!defined(BOSEST_getBosePlayerByDeviceId($hash, $deviceID))) {
        CommandDefine(undef, "BOSE_$deviceID BOSEST $deviceID");
        CommandAttr(undef, "BOSE_$deviceID alias $deviceName");
    }
    return undef;
}

###### WEBSOCKET #######
sub BOSEST_webSocketCallback($$$) {
    my ($hash, $ua, $tx) = @_;
    Log3 $hash, 5, "BOSEST: Callback called";

    if(!$tx->is_websocket) {
        Log3 $hash, 3, "BOSEST: $hash->{NAME}, WebSocket failed, retry.";
        BOSEST_startWebSocketConnection($hash);
        return undef;
    } else {
        Log3 $hash, 3, "BOSEST: $hash->{NAME}, WebSocket connection succeed.";
    }

    #register on message method
    $tx->on(message => sub { my ($tx2, $msg) = @_; BOSEST_webSocketReceivedMsg($hash, $tx2, $msg); });
    #register on finish method
    $tx->on(finish => sub { my $ws = shift; BOSEST_webSocketFinished($hash, $ws); });
    #add recurring ping to mojo ioloop due to inactivity timeout
    $hash->{helper}{mojoping} = Mojo::IOLoop->recurring(19 => sub { BOSEST_webSocketPing($hash, $tx); });
    return undef;
}

sub BOSEST_webSocketFinished($$) {
    my ($hash, $ws) = @_;
    Log3 $hash, 3, "BOSEST: $hash->{NAME}, WebSocket connection dropped - try reconnect.";
    
    #set IP to unknown due to connection drop
    $hash->{helper}{IP} = "unknown";
    
    #set presence & state to offline due to connection drop
    readingsSingleUpdate($hash, "IP", "unknown", 1);
    readingsSingleUpdate($hash, "presence", "offline", 1);
    readingsSingleUpdate($hash, "state", "offline", 1);
    
    Mojo::IOLoop->remove($hash->{helper}{mojoping});
    $ws->finish;
    return undef;
}

sub BOSEST_webSocketPing($$) {
    my ($hash, $tx) = @_;
    #reset requestid for ping to avoid overflows
    $hash->{helper}{requestId} = 1 if($hash->{helper}{requestId} > 9999);
    
    $tx->send('<msg><header deviceID="'.
              $hash->{DEVICEID}.
              '" url="webserver/pingRequest" method="GET"><request requestID="'.
              $hash->{helper}{requestId}.
              '"><info type="new"/></request></header></msg>');
    return undef;
}

sub BOSEST_webSocketReceivedMsg($$$) {
    my ($hash, $tx, $msg) = @_;
    
    Log3 $hash, 5, "BOSEST: $hash->{NAME}, received message.";
    
    #parse XML
    my $xml = "";
    eval {
        $xml = XMLin($msg, KeepRoot => 1, ForceArray => 0, KeyAttr => []);
    };
    
    if($@) {
        Log3 $hash, 3, "BOSEST: Wrong XML format: $@";
    }
        
    #process message
    BOSEST_processXml($hash, $xml);
    
    $tx->resume;
}

sub BOSEST_startWebSocketConnection($) {
    my ($hash) = @_;
    
    Log3 $hash, 5, "BOSEST: $hash->{NAME}, start WebSocket connection.";
    
    $hash->{helper}{requestId} = 1;
    
    $hash->{helper}{useragent} = Mojo::UserAgent->new();
    $hash->{helper}{bosewebsocket} = $hash->{helper}{useragent}->websocket('ws://'.$hash->{helper}{IP}.':8080'
        => ['gabbo'] => sub {
            my ($ua, $tx) = @_;
            BOSEST_webSocketCallback($hash, $ua, $tx);
            return undef;
    });
    
    $hash->{helper}{useragent}->inactivity_timeout(25);
    $hash->{helper}{useragent}->request_timeout(10);
    
    Log3 $hash, 4, "BOSEST: $hash->{NAME}, WebSocket connected.";
    
    return undef;
}

sub BOSEST_checkWebSocketConnection($) {
    my ($hash) = @_;
    if(defined($hash->{helper}{bosewebsocket})) {
        #run mojo loop not longer than 0.5ms
        my $id = Mojo::IOLoop->timer(0.0005 => sub {});
        Mojo::IOLoop->one_tick;
        Mojo::IOLoop->remove($id);
    }
    
    InternalTimer(gettimeofday()+0.8, "BOSEST_checkWebSocketConnection", $hash, 1);
    
    return undef;
}

###### GENERIC ######
sub BOSEST_getBosePlayerByDeviceId($$) {
    my ($hash, $deviceId) = @_;
    
    if (defined($deviceId)) {
		foreach my $fhem_dev (sort keys %main::defs) { 
			return $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'BOSEST' && $main::defs{$fhem_dev}{DEVICEID} eq $deviceId);
		}
	} else {
		return $hash;
	}

    return undef;
}

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

    if($ip eq "unknown") {
        Log3 $hash, 3, "BOSEST: $hash->{NAME}, Can't HTTP GET as long as IP is unknown.";
        return undef;
    }

    my $ua = LWP::UserAgent->new();
    my $req = HTTP::Request->new(GET => 'http://'.$ip.':8090'.$getURI);
    my $response = $ua->request($req);
    if($response->is_success) {
        my $xmlres = "";
        eval {
            $xmlres = XMLin($response->decoded_content, KeepRoot => 1, ForceArray => 0, KeyAttr => []);
        };
        
        if($@) {
            Log3 $hash, 3, "BOSEST: Wrong XML format: $@";
            return undef;
        }
        
        return $xmlres;
    }

    return undef;
}

sub BOSEST_HTTPPOST($$$) {
    my ($hash, $postURI, $postXml) = @_;
    my $ua = LWP::UserAgent->new();
    my $ip = $hash->{helper}{IP};
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

    #TODO update only on change
    if(ref $xmlItem eq ref {}) {
        if(keys %{$xmlItem}) {
            readingsBulkUpdate($hash, $readingName, Encode::encode('UTF-8', $xmlItem));
        } else {
            readingsBulkUpdate($hash, $readingName, "");
        }
    } elsif($xmlItem) {
        readingsBulkUpdate($hash, $readingName, Encode::encode('UTF-8', $xmlItem));
    } else {
        readingsBulkUpdate($hash, $readingName, "");
    }
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

