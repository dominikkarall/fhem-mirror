#############################################################
#
# BOSEST.pm (c) by Dominik Karall, 2016
# dominik karall at gmail dot com
#
# FHEM module to communicate with BOSE SoundTouch system
# API as defined in BOSE SoundTouchAPI_WebServices_v1.0.1.pdf
#
# Version: 1.0.1
#
#############################################################
#
# v1.0.1 - XXXXXXXX
#  - FEATURE: add html documentation (provided by Miami)
#  - BUGFIX: update zone on Player discovery
#  - BUGFIX: fixed some uninitialized variables
#
# v1.0.0 - 20160219
#  - FEATURE: support multi-room (playEverywhere, stopPlayEverywhere)
#  - FEATURE: show current zone members in readings
#  - FEATURE: support createZone <deviceID1>,<deviceID2>,...
#  - FEATURE: support addToZone <deviceID1>,<deviceID2>,...
#  - FEATURE: support removeFromZone <deviceID1>,<deviceID2>,...
#  - FEATURE: add "double-tap" multi-room feature
#             double-tap (<1s) a hardware preset button to
#             enable or disable the multi-room feature
#  - FEATURE: support bass settings
#  - FEATURE: support infoUpdated (e.g. deviceName change)
#  - FEATURE: support mute on/off/toggle
#  - FEATURE: support recent channel list
#             set name recent X
#             names for recent list entries are shown in readings
#  - FEATURE: support channel_07-20 by attribute
#             format:name|location|source|sourceAccount or
#                    name|location|source| if no sourceAccount
#  - FEATURE: support bluetooth/bt-discover/aux mode
#  - FEATURE: support ignoreDeviceIDs for main define
#             format:B23C23FF,A2EC81EF
#  - CHANGE: reading channel_X => channel_0X (e.g. channel_02)
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
#  - support text2speach (via Google)
#  - add readings channel_07-20
#  - save current channel to _07-_20
#  - define own groups of players
#  - update readings only on change
#  - check if websocket finished can be called after websocket re-connected
#  - cleanup all readings on startup (IP=unknown)
#  - use LWP callback functions
#  - fix usage of bulkupdate vs. singleupdate
#  - check if Mojolicious::Lite can be used
#  - support setExtension on-for-timer, ...
#  - use frame ping to keep connection alive
#  - add attribute to ignore deviceID in main
#  - "auto-zone" if 2 or more speakers play the same station
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
    $hash->{AttrFn} = 'BOSEST_Attribute';
    $hash->{AttrList} = 'channel_07 channel_08 channel_09 channel_10 channel_11 ';
    $hash->{AttrList} .= 'channel_12 channel_13 channel_14 channel_15 channel_16 ';
    $hash->{AttrList} .= 'channel_17 channel_18 channel_19 channel_20 ignoreDeviceIDs '.$readingFnAttributes;
    
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
        
        #TODO cleanup all readings on startup (updateIP?)
        
        #allow on/off commands (updateIP?)
        $hash->{helper}{sent_on} = 0;
        $hash->{helper}{sent_off} = 0;
        
        #no websockets connected
        $hash->{helper}{wsconnected} = 0;
        
        #init switchSource
        $hash->{helper}{switchSource} = "";
        
        #FIXME reset all recent_$i entries on startup (must be done here, otherwise readings are displayed when player wasn't found)
    }
    
    if (int(@a) < 3) {
        Log3 $hash, 3, "BOSEST: BOSE SoundTouch v1.0.1";
        #start discovery process 30s delayed
        InternalTimer(gettimeofday()+30, "BOSEST_startDiscoveryProcess", $hash, 0);
    }
    
    return undef;
}

sub BOSEST_Attribute($$$$) {
    my ($mode, $devName, $attrName, $attrValue) = @_;
    
    if($mode eq "set") {
        #check if there are 3 | in the attrValue
        #update reading for channel_X
        #currently nothing to do
    } elsif($mode eq "del") {
        #currently nothing to do
        #update reading for channel_X
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
                    mute:on,off,toggle recent source:bluetooth,bt-discover,aux 
                    nextTrack:noArg prevTrack:noArg playTrack 
                    playEverywhere:noArg stopPlayEverywhere:noArg createZone addToZone removeFromZone 
                    stop:noArg pause:noArg channel:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 
                    volume:slider,0,1,100 bass:slider,1,1,10";
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
    } elsif($workType eq "bass") {
        return "BOSEST: bass requires bass (1-10) as additional parameter" if(int(@params) < 1);
        #params[0] = bass value
        BOSEST_setBass($hash, $params[0]);
    } elsif($workType eq "mute") {
        return "BOSEST: mute requires on/off/toggle as additional parameter" if(int(@params) < 1);
        #params[0] = mute value
        BOSEST_setMute($hash, $params[0]);
    } elsif($workType eq "recent") {
        return "BOSEST: recebt requires number as additional parameter" if(int(@params) < 1);
        #params[0] = recent value
        BOSEST_setRecent($hash, $params[0]);
    } elsif($workType eq "source") {
        return "BOSEST: source requires bluetooth/aux as additional parameter" if(int(@params) < 1);
        #params[0] = source value
        BOSEST_setSource($hash, $params[0]);
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
    } elsif($workType eq "playTrack") {
        return "BOSEST: playTrack requires track name as additional parameters" if(int(@params) < 1);
        #params[0] = track name for search
        BOSEST_playTrack($hash, $params[0]);
    } elsif($workType eq "playEverywhere") {
        BOSEST_playEverywhere($hash);
    } elsif($workType eq "stopPlayEverywhere") {
        BOSEST_stopPlayEverywhere($hash);
    } elsif($workType eq "createZone") {
        return "BOSEST: createZone requires deviceIDs as additional parameter" if(int(@params) < 1);
        #params[0] = deviceID channel
        BOSEST_createZone($hash, $params[0]);
    } elsif($workType eq "addToZone") {
        return "BOSEST: addToZone requires deviceID as additional parameter" if(int(@params) < 1);
        #params[0] = deviceID channel
        BOSEST_addToZone($hash, $params[0]);
    } elsif($workType eq "removeFromZone") {
        return "BOSEST: removeFromZone requires deviceID as additional parameter" if(int(@params) < 1);
        #params[0] = deviceID channel
        BOSEST_removeFromZone($hash, $params[0]);
    } else {
        return "BOSEST: Unknown argument $workType";
    }
    
    return undef;
}

#DEVELOPNEWFUNCTION-2 (create own function)
sub BOSEST_stopPlayEverywhere($) {
    my ($hash) = @_;
    my $postXmlHeader = "<zone master=\"$hash->{DEVICEID}\">";
    my $postXmlFooter = "</zone>";
    my $postXml = "";
    
    my @players = BOSEST_getAllBosePlayers($hash);
    foreach my $playerHash (@players) {
        $postXml .= "<member ipaddress=\"".$playerHash->{helper}{IP}."\">".$playerHash->{DEVICEID}."</member>" if($playerHash->{helper}{IP} ne "unknown");
    }
    
    $postXml = $postXmlHeader.$postXml.$postXmlFooter;
    
    if(BOSEST_HTTPPOST($hash, '/removeZoneSlave', $postXml)) {
        #ok
    }
}

sub BOSEST_playEverywhere($) {
    my ($hash) = @_;
    my $postXmlHeader = "<zone master=\"$hash->{DEVICEID}\" senderIPAddress=\"$hash->{helper}{IP}\">";
    my $postXmlFooter = "</zone>";
    my $postXml = "";
    
    my @players = BOSEST_getAllBosePlayers($hash);
    foreach my $playerHash (@players) {
        #don't add myself as member, I'm the master
        if($playerHash->{DEVICEID} ne $hash->{DEVICEID}) {
            $postXml .= "<member ipaddress=\"".$playerHash->{helper}{IP}."\">".$playerHash->{DEVICEID}."</member>" if($playerHash->{helper}{IP} ne "unknown");
        }
    }
    
    $postXml = $postXmlHeader.$postXml.$postXmlFooter;
    
    if(BOSEST_HTTPPOST($hash, '/setZone', $postXml)) {
        #ok
    }
    
    return undef;
}

sub BOSEST_createZone($$) {
    my ($hash, $deviceIds) = @_;
    my @devices = split(",", $deviceIds);
    my $postXmlHeader = "<zone master=\"$hash->{DEVICEID}\" senderIPAddress=\"$hash->{helper}{IP}\">";
    my $postXmlFooter = "</zone>";
    my $postXml = "";
    
    foreach my $deviceId (@devices) {
        my $playerHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceId);
        
        return undef if(!defined($playerHash));
        
        $postXml .= "<member ipaddress=\"".$playerHash->{helper}{IP}."\">".$playerHash->{DEVICEID}."</member>" if($playerHash->{helper}{IP} ne "unknown");
    }
    
    $postXml = $postXmlHeader.$postXml.$postXmlFooter;
    
    if(BOSEST_HTTPPOST($hash, '/setZone', $postXml)) {
        #ok
    }
    
    return undef;
}

sub BOSEST_addToZone($$) {
    my ($hash, $deviceIds) = @_;
    my @devices = split(",", $deviceIds);
    my $postXmlHeader = "<zone master=\"$hash->{DEVICEID}\" senderIPAddress=\"$hash->{helper}{IP}\">";
    my $postXmlFooter = "</zone>";
    my $postXml = "";
    
    foreach my $deviceId (@devices) {
        my $playerHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceId);
        
        return undef if(!defined($playerHash));
        
        $postXml .= "<member ipaddress=\"".$playerHash->{helper}{IP}."\">".$playerHash->{DEVICEID}."</member>" if($playerHash->{helper}{IP} ne "unknown");
    }
    
    $postXml = $postXmlHeader.$postXml.$postXmlFooter;
    
    if(BOSEST_HTTPPOST($hash, '/addZoneSlave', $postXml)) {
        #ok
    }
    
    return undef;
}

sub BOSEST_removeFromZone($$) {
    my ($hash, $deviceIds) = @_;
    my @devices = split(",", $deviceIds);
    my $postXmlHeader = "<zone master=\"$hash->{DEVICEID}\">";
    my $postXmlFooter = "</zone>";
    my $postXml = "";
    
    foreach my $deviceId (@devices) {
        my $playerHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceId);
        
        return undef if(!defined($playerHash));
        
        $postXml .= "<member ipaddress=\"".$playerHash->{helper}{IP}."\">".$playerHash->{DEVICEID}."</member>" if($playerHash->{helper}{IP} ne "unknown");
    }
    
    $postXml = $postXmlHeader.$postXml.$postXmlFooter;
    
    if(BOSEST_HTTPPOST($hash, '/removeZoneSlave', $postXml)) {
        #ok
    }
    
    return undef;
}

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

sub BOSEST_setRecent($$) {
    my ($hash, $nr) = @_;
    
    if(!defined($hash->{helper}{recents}{$nr}{itemName})) {
        #recent entry not found
        return undef;
    }
    
    BOSEST_setContentItem($hash,
                          $hash->{helper}{recents}{$nr}{itemName},
                          $hash->{helper}{recents}{$nr}{location},
                          $hash->{helper}{recents}{$nr}{source},
                          $hash->{helper}{recents}{$nr}{sourceAccount});

    return undef;
}

sub BOSEST_setContentItem($$$$$) {
    my ($hash, $itemName, $location, $source, $sourceAccount) = @_;
    
    my $postXml = "<ContentItem source=\"".
              $source.
              "\" sourceAccount=\"".
              $sourceAccount.
              "\" location=\"".
              $location.
              "\">".
              "<itemName>".
              $itemName.
              "</itemName>".
              "</ContentItem>";
              
    if(BOSEST_HTTPPOST($hash, "/select", $postXml)) {
        #ok
    }
    return undef;
}

sub BOSEST_setBass($$) {
    my ($hash, $bass) = @_;
    $bass = $bass - 10;
    #FIXME currently not working
    my $postXml = "<bass>$bass</bass>";
    if(BOSEST_HTTPPOST($hash, '/bass', $postXml)) {
        #readingsSingleUpdate($hash, "bass", $bass+10, 1);
    }
    #FIXME error handling
    return undef;
}

sub BOSEST_setVolume($$) {
    my ($hash, $volume) = @_;
    my $postXml = '<volume>'.$volume.'</volume>';
    if(BOSEST_HTTPPOST($hash, '/volume', $postXml)) {
        #readingsSingleUpdate($hash, "volume", $volume, 1);
    }
    #FIXME error handling
    return undef;
}

sub BOSEST_setMute($$) {
    my ($hash, $mute) = @_;
    
    if(($mute eq "on" && $hash->{READINGS}{mute}{VAL} eq "false") or 
       ($mute eq "off" && $hash->{READINGS}{mute}{VAL} eq "true") or
       ($mute eq "toggle")) {
        BOSEST_sendKey($hash, "MUTE");
    }
    
    return undef;
}

sub BOSEST_setSource($$) {
    my ($hash, $source) = @_;
    
    $hash->{helper}{switchSource} = uc $source;
    
    if($hash->{helper}{switchSource} eq "") {
        return undef;
    }
    
    if($hash->{helper}{switchSource} eq "BT-DISCOVER" &&
       ReadingsVal($hash->{NAME}, "connectionStatusInfo", "") eq "DISCOVERABLE") {
        $hash->{helper}{switchSource} = "";
        return undef;
    }
    
    if($hash->{helper}{switchSource} eq ReadingsVal($hash->{NAME}, "source", "") &&
       ReadingsVal($hash->{NAME}, "connectionStatusInfo", "") ne "DISCOVERABLE") {
        $hash->{helper}{switchSource} = "";
        return undef;
    }
    
    #source is not switchSource yet
    BOSEST_sendKey($hash, "AUX_INPUT");

    return undef;
}

sub BOSEST_setPreset($$) {
    my ($hash, $preset) = @_;
    if($preset > 0 && $preset < 7) {
        BOSEST_sendKey($hash, "PRESET_".$preset);
    } else {
        #set channel based on AttrVal
        my $channelVal = AttrVal($hash->{NAME}, sprintf("channel_%02d", $preset), "0");
        return undef if($channelVal eq "0");
        my @channel = split("\\|", $channelVal);
        $channel[3] = "" if(!defined($channel[3]));
        Log3 $hash, 5, "BOSEST: AttrVal: $channel[0], $channel[1], $channel[2], $channel[3]";
        #format: itemName|location|source|sourceAccount
        BOSEST_setContentItem($hash, $channel[0], $channel[1], $channel[2], $channel[3]);
    }
    return undef;
}

sub BOSEST_play($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "PLAY");
    return undef;
}

sub BOSEST_stop($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "STOP");
    return undef;
}

sub BOSEST_pause($) {
    my ($hash) = @_;
    BOSEST_sendKey($hash, "PAUSE");
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

sub BOSEST_playTrack($$) {
    my ($hash, $trackName) = @_;
    
    foreach my $source (@{$hash->{helper}{sources}}) {
        if($source->{source} eq "STORED_MUSIC") {
            Log3 $hash, 3, "BOSEST: Search for $trackName on $source->{source}";
            if(my $xmlTrack = BOSEST_searchTrack($hash, $source->{sourceAccount}, $trackName)) {
                BOSEST_setContentItem($hash,
                                      $xmlTrack->{itemName},
                                      $xmlTrack->{location},
                                      $xmlTrack->{source},
                                      $xmlTrack->{sourceAccount});
                last;
            }
        }
    }
    
    return undef;
}

sub BOSEST_searchTrack($$$) {
    my ($hash, $dlnaUid, $trackName) = @_;
    
    my $postXml = '<search source="STORED_MUSIC" sourceAccount="'.
                  $dlnaUid.
                  '"><startItem>1</startItem><numItems>100</numItems><searchTerm filter="track">'.
                  $trackName.
                  '</searchTerm></search>';

    if(my $xmlSearchResult = BOSEST_HTTPPOST($hash, '/search', $postXml)) {
        #return first item from search results
        if($xmlSearchResult->{searchResponse}->{items}) {
            return $xmlSearchResult->{searchResponse}->{items}->{item}[0]->{ContentItem};
        }
    }
    return undef;
}

###### UPDATE VIA HTTP ######
sub BOSEST_updateInfo($$) {
    my ($hash, $deviceId) = @_;
    my $info = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/info");
    BOSEST_processXml($hash, $info);
    return undef;
}

sub BOSEST_updateSources($$) {
    my ($hash, $deviceId) = @_;
    my $sources = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/sources");
    BOSEST_processXml($hash, $sources);
    return undef;
}

sub BOSEST_updatePresets($$) {
    my ($hash, $deviceId) = @_;
    my $presets = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/presets");
    BOSEST_processXml($hash, $presets);
    return undef;    
}

sub BOSEST_updateZone($$) {
    my ($hash, $deviceId) = @_;
    my $zone = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/getZone");
    BOSEST_processXml($hash, $zone);
    return undef;    
}

sub BOSEST_updateVolume($$) {
    my ($hash, $deviceId) = @_;
    my $volume = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/volume");
    BOSEST_processXml($hash, $volume);
    return undef;    
}

sub BOSEST_updateBass($$) {
    my ($hash, $deviceId) = @_;
    my $bass = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/bass");
    BOSEST_processXml($hash, $bass);
    return undef;
}

sub BOSEST_updateNowPlaying($$) {
    my ($hash, $deviceId) = @_;
    my $nowPlaying = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/now_playing");
    BOSEST_processXml($hash, $nowPlaying);
    return undef;
}

sub BOSEST_checkDoubleTap($$) {
    my ($hash, $channel) = @_;
    
    if(!defined($hash->{helper}{dt_nowSelectionUpdatedTS}) or $channel ne $hash->{helper}{dt_nowSelectionUpdatedCH}) {
        $hash->{helper}{dt_nowSelectionUpdatedTS} = gettimeofday();
        $hash->{helper}{dt_nowSelectionUpdatedCH} = $channel;
        $hash->{helper}{dt_lastChange} = 0;
        return undef;
    }
    
    my $timeDiff = gettimeofday() - $hash->{helper}{dt_nowSelectionUpdatedTS};
    if($timeDiff < 1) {
        if(ReadingsVal($hash->{NAME}, "zoneMaster", "") eq $hash->{DEVICEID}) {
            BOSEST_stopPlayEverywhere($hash);
            $hash->{helper}{dt_lastChange} = gettimeofday();
        } elsif(ReadingsVal($hash->{NAME}, "zoneMaster", "") eq "") {
            #make sure that play isn't started just after stop, that might confuse the player
            my $timeDiffMasterChange = gettimeofday() - $hash->{helper}{dt_lastChange};
            if($timeDiffMasterChange > 2) {
                BOSEST_playEverywhere($hash);
                $hash->{helper}{dt_lastChange} = gettimeofday();
            }
        }
    }
    
    $hash->{helper}{dt_nowSelectionUpdatedTS} = gettimeofday();
    
    return undef;
}

###### XML PROCESSING ######
sub BOSEST_processXml($$) {
    my ($hash, $wsxml) = @_;
    
    if($wsxml->{updates}) {
        if($wsxml->{updates}->{nowPlayingUpdated}) {
            if($wsxml->{updates}->{nowPlayingUpdated}->{nowPlaying}) {
                BOSEST_parseAndUpdateNowPlaying($hash, $wsxml->{updates}->{nowPlayingUpdated}->{nowPlaying});
                if($hash->{helper}{switchSource} ne "") {
                    BOSEST_setSource($hash, $hash->{helper}{switchSource});
                }
            }
        } elsif ($wsxml->{updates}->{volumeUpdated}) {
            BOSEST_parseAndUpdateVolume($hash, $wsxml->{updates}->{volumeUpdated}->{volume});
        } elsif ($wsxml->{updates}->{nowSelectionUpdated}) {
            BOSEST_parseAndUpdateChannel($hash, $wsxml->{updates}->{nowSelectionUpdated}->{preset});
            BOSEST_checkDoubleTap($hash, $wsxml->{updates}->{nowSelectionUpdated}->{preset}->{id});
        } elsif ($wsxml->{updates}->{recentsUpdated}) {
            BOSEST_parseAndUpdateRecents($hash, $wsxml->{updates}->{recentsUpdated}->{recents});
        } elsif ($wsxml->{updates}->{connectionStateUpdated}) {
            #BOSE SoundTouch team says that it's not necessary to handle this one
        } elsif ($wsxml->{updates}->{clockDisplayUpdated}) {
            #TODO handle clockDisplayUpdated (feature currently unknown)
        } elsif ($wsxml->{updates}->{presetsUpdated}) {
            BOSEST_parseAndUpdatePresets($hash, $wsxml->{updates}->{presetsUpdated}->{presets});
        } elsif ($wsxml->{updates}->{zoneUpdated}) {
            #zoneUpdated is just a notification with no data
            BOSEST_updateZone($hash, $hash->{DEVICEID});
        } elsif ($wsxml->{updates}->{bassUpdated}) {
            #bassUpdated is just a notification with no data
            BOSEST_updateBass($hash, $hash->{DEVICEID});
        } elsif ($wsxml->{updates}->{infoUpdated}) {
            #infoUpdated is just a notification with no data
            BOSEST_updateInfo($hash, $hash->{DEVICEID});
        } elsif ($wsxml->{updates}->{sourcesUpdated}) {
            #sourcesUpdated is just a notification with no data
            BOSEST_updateSources($hash, $hash->{DEVICEID});
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
    } elsif($wsxml->{bass}) {
        BOSEST_parseAndUpdateBass($hash, $wsxml->{bass});
    } elsif($wsxml->{zone}) {
        BOSEST_parseAndUpdateZone($hash, $wsxml->{zone});
    } elsif($wsxml->{sources}) {
        BOSEST_parseAndUpdateSources($hash, $wsxml->{sources}->{sourceItem});
    }
    
    return undef;
}

sub BOSEST_parseAndUpdateSources($$) {
    my ($hash, $sourceItems) = @_;
    
    $hash->{helper}->{sources} = ();
    
    Log3 $hash, 3, "BOSEST: Update sources...";
    
    foreach my $sourceItem (@{$sourceItems}) {
        Log3 $hash, 3, "BOSEST: Add $sourceItem->{source}";
        #save source information
        # - source (BLUETOOTH, STORED_MUSIC, ...)
        # - sourceAccount
        # - status
        # - isLocal
        # - name
        $sourceItem->{isLocal} = "" if(!defined($sourceItem->{isLocal}));
        $sourceItem->{sourceAccount} = "" if(!defined($sourceItem->{sourceAccount}));
        $sourceItem->{sourceAccount} = "" if(!defined($sourceItem->{sourceAccount}));
        
        my %source = (source => $sourceItem->{source},
                      sourceAccount => $sourceItem->{sourceAccount},
                      status => $sourceItem->{status},
                      isLocal => $sourceItem->{isLocal},
                      name => $sourceItem->{content});
                      
        push @{$hash->{helper}->{sources}}, \%source;
    }
    
    return undef;
}

sub BOSEST_parseAndUpdateChannel($$) {
    my ($hash, $preset) = @_;
    
    readingsBeginUpdate($hash);
    if($preset->{id} ne "0") {
        BOSEST_XMLUpdate($hash, "channel", $preset->{id});
    } else {
        $preset->{ContentItem}->{sourceAccount} = "" if(!defined($preset->{ContentItem}->{sourceAccount}));
        
        my $channelString = $preset->{ContentItem}->{itemName}."|".$preset->{ContentItem}->{location}."|".
                            $preset->{ContentItem}->{source}."|".$preset->{ContentItem}->{sourceAccount};
                            
        foreach my $channelNr (7..20) {
            my $channelVal = AttrVal($hash->{NAME}, sprintf("channel_%02d", $channelNr), "0");
            if($channelVal eq $channelString) {
                BOSEST_XMLUpdate($hash, "channel", $channelNr);
            }
        }
    }
    readingsEndUpdate($hash, 1);
    
    return undef;
}

sub BOSEST_parseAndUpdateZone($$) {
    my ($hash, $zone) = @_;
    readingsBeginUpdate($hash);
    BOSEST_XMLUpdate($hash, "zoneMaster", $zone->{master});
    
    my $i = 1;
    if($zone->{member}) {
        foreach my $member (@{$zone->{member}}) {
            my $player = BOSEST_getBosePlayerByDeviceId($hash, $member->{content});
            BOSEST_XMLUpdate($hash, "zoneMember_$i", $player->{NAME});
            $i++;
        }
    }
    
    while ($i < 20) {
        if(defined($hash->{READINGS}{"zoneMember_$i"})) {
            BOSEST_XMLUpdate($hash, "zoneMember_$i", "");
        }
        $i++;
    }
    
    readingsEndUpdate($hash, 1);
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
        BOSEST_XMLUpdate($hash, sprintf("channel_%02d", $preset), $activePresets{$preset});
    }
    
    readingsEndUpdate($hash, 1);
    return undef;
}

sub BOSEST_parseAndUpdateRecents($$) {
    my ($hash, $recents) = @_;
    my $i = 1;
    
    readingsBeginUpdate($hash);

    foreach my $recentEntry (@{$recents->{recent}}) {
        BOSEST_XMLUpdate($hash, sprintf("recent_%02d", $i), $recentEntry->{contentItem}->{itemName});
        $hash->{helper}{recents}{$i}{location} = $recentEntry->{contentItem}->{location};
        $hash->{helper}{recents}{$i}{source} = $recentEntry->{contentItem}->{source};
        $hash->{helper}{recents}{$i}{sourceAccount} = $recentEntry->{contentItem}->{sourceAccount};
        $hash->{helper}{recents}{$i}{itemName} = $recentEntry->{contentItem}->{itemName};
        $i++;
    }
    
    readingsEndUpdate($hash, 1);
    
    return undef;
}

sub BOSEST_parseAndUpdateVolume($$) {
    my ($hash, $volume) = @_;
    readingsBeginUpdate($hash);
    BOSEST_XMLUpdate($hash, "volume", $volume->{actualvolume});
    BOSEST_XMLUpdate($hash, "mute", $volume->{muteenabled});
    readingsEndUpdate($hash, 1);
    return undef;
}

sub BOSEST_parseAndUpdateBass($$) {
    my ($hash, $bass) = @_;
    my $currBass = $bass->{actualbass} + 10;
    readingsBeginUpdate($hash);
    BOSEST_XMLUpdate($hash, "bass", $currBass);
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
    if($nowPlaying->{connectionStatusInfo}) {
        BOSEST_XMLUpdate($hash, "connectionStatusInfo", $nowPlaying->{connectionStatusInfo}->{status});
    } else {
        BOSEST_XMLUpdate($hash, "connectionStatusInfo", "");
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
    my $ignoreDeviceIDs = AttrVal($hash->{NAME}, "ignoreDeviceIDs", "");
    
    delete($hash->{helper}{DISCOVERY_PID});
    
    #start discovery again after 60s
    InternalTimer(gettimeofday()+60, "BOSEST_startDiscoveryProcess", $hash, 1);

    for($i = 1; $i < @commands; $i = $i+2) {
        my $command = $commands[$i];
        my @params = split(",", $commands[$i+1]);
        my $deviceId = $params[0];
        
        next if($ignoreDeviceIDs =~ /$deviceId/);

        if($command eq "commandDefineBOSE") {
            my $deviceName = $params[1];
            BOSEST_commandDefine($hash, $deviceId, $deviceName);
        } elsif($command eq "updateIP") {
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
        #get current bass settings
        BOSEST_updateBass($deviceHash, $deviceID);
        #get current zone settings
        BOSEST_updateZone($deviceHash, $deviceID);
        #get current sources
        BOSEST_updateSources($deviceHash, $deviceID);
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
        #avoid multiple websocket connections to one speaker
        $hash->{helper}{wsconnected} += 1;
        
        if($hash->{helper}{wsconnected} > 1) {
            $tx->finish;
            return undef;
        }
        
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
    
    #connection dropped
    $hash->{helper}{wsconnected} -= 1;
    
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
        $xml = XMLin($msg, KeepRoot => 1, ForceArray => [qw(item member recent)], KeyAttr => []);
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
    
    if($hash->{helper}{wsconnected} > 0) {
        Log3 $hash, 3, "BOSEST: There are already $hash->{helper}{wsconnected} WebSockets connected.";
        Log3 $hash, 3, "BOSEST: Prevent new connections.";
        return undef;
    }
    
    $hash->{helper}{useragent} = Mojo::UserAgent->new() if(!defined($hash->{helper}{useragent}));
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
sub BOSEST_getSourceAccountByName($$) {
    my ($hash, $sourceName) = @_;
    
    foreach my $source (@{$hash->{helper}{sources}}) {
        if($source->{name} eq $sourceName) {
            return $source->{sourceAccount};
        }
    }
    
    return undef;
}

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

sub BOSEST_getAllBosePlayers($) {
    my ($hash) = @_;
    my @players = ();
    
		foreach my $fhem_dev (sort keys %main::defs) { 
			push @players, $main::defs{$fhem_dev} if($main::defs{$fhem_dev}{TYPE} eq 'BOSEST' && $main::defs{$fhem_dev}{DEVICEID} ne "0");
		}
		
    return @players;
}

sub BOSEST_sendKey($$) {
    my ($hash, $key) = @_;
    my $postXml = '<key state="press" sender="Gabbo">'.$key.'</key>';
    if(BOSEST_HTTPPOST($hash, '/key', $postXml)) {
        select(undef, undef, undef, .05); #sleep 50ms
        $postXml = '<key state="release" sender="Gabbo">'.$key.'</key>';
        if(BOSEST_HTTPPOST($hash, '/key', $postXml)) {
            #FIXME success
        }
    }
    #FIXME error handling
    return undef;
}

sub BOSEST_HTTPGET($$$) {
    my ($hash, $ip, $getURI) = @_;

    if(!defined($ip) or $ip eq "unknown") {
        Log3 $hash, 3, "BOSEST: $hash->{NAME}, Can't HTTP GET as long as IP is unknown.";
        return undef;
    }

    my $ua = LWP::UserAgent->new();
    my $req = HTTP::Request->new(GET => 'http://'.$ip.':8090'.$getURI);
    my $response = $ua->request($req);
    if($response->is_success) {
        my $xmlres = "";
        eval {
            $xmlres = XMLin($response->decoded_content, KeepRoot => 1, ForceArray => [qw(item member recent)], KeyAttr => []);
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
    Log3 $hash, 4, "BOSEST: set ".$postURI." => ".$postXml;
    $req->content($postXml);

    my $response = $ua->request($req);
    if($response->is_success) {
        Log3 $hash, 4, "BOSEST: success: ".$response->decoded_content;
        my $xmlres = "";
        eval {
            $xmlres = XMLin($response->decoded_content, KeepRoot => 1, ForceArray => [qw(item member recent)], KeyAttr => []);
        };
        
        if($@) {
            Log3 $hash, 3, "BOSEST: Wrong XML format: $@";
            return undef;
        }
        
        return $xmlres;
    } else {
        #TODO return error
        Log3 $hash, 3, "BOSEST: failed: ".$response->status_line;
        return undef;
    }
    
    return undef;
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
  BOSEST is used to control a BOSE SoundTouch system (one or more SoundTouch 10, 20 or 30 devices)<br><br>
	<b>Note:</b> The followig libraries  are required for this module:
		<ul><li>libwww-perl <li>libmojolicious-perl <li>libxml-simple-perl <li>libnet-bonjour-perl <li>libev-perl</li><br>
		Use <b>sudo apt-get install libwww-perl libmojolicious-perl libxml-simple-perl libnet-bonjour-perl libev-perl</b> to install this libraries.<br>Please note: 
		libmojolicious-perl must be >=5.54, but under wheezy is only 2.x avaible.<br>
		Use <b>sudo apt-get install cpanminus</b> and <b>sudo cpanm Mojolicious</b> to update to the newest version</ul><br>

  <a name="BOSESTdefine" id="BOSESTdefine"></a>
    <b>Define</b>
  <ul>
    <code>define &lt;name&gt; BOSEST</code><br>
    <br>
    Example:
    <ul>
      <code>define bosesystem BOSEST</code><br>
      Defines BOSE SoundTouch system. All speakers will show up after 60s under Unsorted.<br/>
    </ul>
	</ul>
  
  <br>

  <a name="BOSESTset" id="BOSESTset"></a>
  <b>Set</b>
 		<ul>
    <code>set &lt;name&gt; &lt;command&gt; [&lt;parameter&gt;]</code><br>
        The following commands are defined:<br>
        <ul>
          <li><b>on</b> &nbsp;&nbsp;-&nbsp;&nbsp; powers on the device</li>
          <li><b>off</b> &nbsp;&nbsp;-&nbsp;&nbsp; turns the device off</li>
          <li><b>power</b> &nbsp;&nbsp;-&nbsp;&nbsp; toggles on/off</li>
          <li><b>volume</b> 0...100 &nbsp;&nbsp;-&nbsp;&nbsp; sets the volume level in percentage</li>
          <li><b>channel</b> 0...20 &nbsp;&nbsp;-&nbsp;&nbsp; selects present to play</li>
          <li><b>play</b> &nbsp;&nbsp;-&nbsp;&nbsp; starts/resumes to play </li>
          <li><b>pause</b> &nbsp;&nbsp;-&nbsp;&nbsp; pauses the playback</li>
          <li><b>stop</b> &nbsp;&nbsp;-&nbsp;&nbsp; stops playback</li>
          <li><b>nextTrack</b> &nbsp;&nbsp;-&nbsp;&nbsp; plays next track</li>
          <li><b>prevTrack</b> &nbsp;&nbsp;-&nbsp;&nbsp; plays previous track</li>
          <li><b>mute</b> on,off, toggle &nbsp;&nbsp;-&nbsp;&nbsp; controls volume mute</li>
          <li><b>bass</b> 1---10 &nbsp;&nbsp;-&nbsp;&nbsp; sets the bass level</li>
          <li><b>recent</b> x &nbsp;&nbsp;-&nbsp;&nbsp; lists x names in the recent list in readings</li>
          <li><b>source</b> bluetooth,bt-discover,aux mode&nbsp;&nbsp;-&nbsp;&nbsp; select a local source</li><br>
        </ul>
        <ul>Multiroom commands:
          <li><b>createZone</b> deviceID &nbsp;&nbsp;-&nbsp;&nbsp; creates multiroom zone (defines <code>&lt;name&gt;</code> as zoneMaster) </li>          
          <li><b>addToZone</b> deviceID &nbsp;&nbsp;-&nbsp;&nbsp; adds device <code>&lt;name&gt;</code> to multiroom zone</li>
          <li><b>removeFromZone</b> deviceID &nbsp;&nbsp;-&nbsp;&nbsp; removes device <code>&lt;name&gt;</code> from multiroom zone</li>
          <li><b>playEverywhere</b>  &nbsp;&nbsp;-&nbsp;&nbsp; plays sound of  device <code>&lt;name&gt;</code> on all others devices</li>
          <li><b>stopPlayEverywhere</b>  &nbsp;&nbsp;-&nbsp;&nbsp; stops playing sound on all devices</li>
        </ul>
      </ul><br>
  
    <a name="BOSESTget" id="BOSESTget"></a>
  	<b>Get</b>
	  <ul>
	    <code>n/a</code>
 	 </ul>
 	 <br>

  </ul>
  
</ul> 
</ul>

=end html
=cut

