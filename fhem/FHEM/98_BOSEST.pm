#############################################################
#
# BOSEST.pm (c) by Dominik Karall, 2016
# dominik karall at gmail dot com
#
# FHEM module to communicate with BOSE SoundTouch system
# API as defined in BOSE SoundTouchAPI_WebServices_v1.0.1.pdf
#
# Version: 1.5.3
#
#############################################################
#
# v1.5.3 - 201604XX
#  - FEATURE: support speak channel name
#             attr <name> speakChannel 2-6
#             attr <name> speakChannel 2,3,5,6
#
# v1.5.2 - 20160403
#  - FEATURE: support clock display (SoundTouch 20/30)
#             set <name> clock enable/disable
#
# v1.5.1 - 20160330
#  - CHANGE: updated documentation (again many thx to Miami!)
#  - FEATURE: support triple-tap (currently no function implemented: any ideas? :))
#  - CHANGE: change back channel even after speakOff
#  - BUGFIX: unitialized value fixed
#
# v1.5.0 - 20160306
#  - FEATURE: support SetExtensions (on-for-timer,...)
#  - FEATURE: support TTS (TextToSpeach) via Google Translate
#             set <name> speak "This is a test message"
#  - FEATURE: support volume control for TTS
#             set <name> speak "This message has different volume" 30
#  - FEATURE: support different languages for TTS
#             set <name> speak "Das ist ein deutscher Test" de
#             set <name> speak "Das ist ein deutscher Test" 30 de
#  - FEATURE: support off (instead of resume) after TTS messages (restores only volume settings)
#             set <name> speakOff "Music is going to switch off now. Good night." 30 en
#  - FEATURE: speak "not available" text on Google Captcha
#             can be disabled by ttsSpeakOnError = 0
#  - FEATURE: set default TTS language via ttsLanguage attribute
#  - FEATURE: automatically add DLNA server running on the same 
#             server as FHEM to the BOSE library
#  - FEATURE: automatically add all DLNA servers to BOSE library
#             requires autoAddDLNAServers = 1 attribute for "main" (not players!)
#  - FEATURE: reuse cached TTS files for 30 days
#  - FEATURE: set DLNA TTS directory via ttsDirectory attribute
#  - FEATURE: set DLNA TTS server via ttsDLNAServer attribute
#             only needed if the DLNA server is not the FHEM server
#  - FEATURE: support ttsVolume for speak
#             ttsVolume = 20 (set volume 20 for speak)
#             ttsVolume = +20 (increase volume by 20 from current level)
#  - FEATURE: add html documentation (provided by Miami)
#  - FEATURE: support relative volume settings with +/-
#             set <name> volume +3
#             set <name> speak "This is a louder message" +10
#  - FEATURE: new reading "connectedDLNAServers" (blanks are replaced by "-")
#  - FEATURE: support add/remove DLNA servers to the BOSE library
#             set <name> addDLNAServer RPi
#             set <name> removeDLNAServer RPi
#  - FEATURE: add readings for channel_07-20
#  - FEATURE: support saveChannel to save current channel to channel_07-20
#  - FEATURE: support bass settings only if available (/bassCapabilities)
#  - FEATURE: support bluetooth only if available (/sources)
#  - FEATURE: support switch source to airplay (untested)
#  - BUGFIX: update zone on Player discovery
#  - BUGFIX: fixed some uninitialized variables
#  - CHANGE: limit recent_X readings to 15 max
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
#  - support multiroom volume
#  - speak channel name after preset change (configure per preset)
#  - adduserattr function??
#  - support http://... for streaming via DLNA
#  - TTS code cleanup (group functions logically)
#  - delete TTS files after 30 days
#  - define own groups of players
#  - update readings only on change
#  - check if websocket finished can be called after websocket re-connected
#  - cleanup all readings on startup (IP=unknown)
#  - fix usage of bulkupdate vs. singleupdate
#  - check if Mojolicious::Lite can be used
#  - check if Mojolicious should be used for HTTPGET/HTTPPOST
#  - use frame ping to keep connection alive
#  - ramp up/down volume support
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
use SetExtensions;

use Data::Dumper;
use Digest::MD5 qw(md5_hex);
use File::stat;
use IO::Socket::INET;
use LWP::UserAgent;
use Mojolicious 5.54;
use Net::Bonjour;
use Scalar::Util qw(looks_like_number);
use XML::Simple;

my $BOSEST_GOOGLE_NOT_AVAILABLE_TEXT = "Hello, I'm sorry, but Google Translate is currently not available.";
my $BOSEST_GOOGLE_NOT_AVAILABLE_LANG = "en";

sub BOSEST_Initialize($) {
    my ($hash) = @_;
    
    $hash->{DefFn} = 'BOSEST_Define';
    $hash->{UndefFn} = 'BOSEST_Undef';
    $hash->{GetFn} = 'BOSEST_Get';
    $hash->{SetFn} = 'BOSEST_Set';
    $hash->{AttrFn} = 'BOSEST_Attribute';
    $hash->{AttrList} = 'channel_07 channel_08 channel_09 channel_10 channel_11 ';
    $hash->{AttrList} .= 'channel_12 channel_13 channel_14 channel_15 channel_16 ';
    $hash->{AttrList} .= 'channel_17 channel_18 channel_19 channel_20 ignoreDeviceIDs ';
    $hash->{AttrList} .= 'ttsDirectory ttsLanguage ttsSpeakOnError ttsDLNAServer ttsVolume ';
    $hash->{AttrList} .= 'autoAddDLNAServers speakChannel '.$readingFnAttributes;
    
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
        #create mojo useragent
        $hash->{helper}{useragent} = Mojo::UserAgent->new() if(!defined($hash->{helper}{useragent}));
        
        #init statecheck
        $hash->{helper}{stateCheck}{enabled} = 0;
        
        #init switchSource
        $hash->{helper}{switchSource} = "";
        
        #init speak channel functionality
        $hash->{helper}{lastSpokenChannel} = "";
        
        #FIXME reset all recent_$i entries on startup (must be done here, otherwise readings are displayed when player wasn't found)
    }
    
    #init dlnaservers
    $hash->{helper}{dlnaServers} = "";
    
    #init supported source commands
    $hash->{helper}{supportedSourcesCmds} = "";
    $hash->{helper}{supportedBassCmds} = "";
    
    if (int(@a) < 3) {
        Log3 $hash, 3, "BOSEST: BOSE SoundTouch v1.5.3";
        #start discovery process 30s delayed
        InternalTimer(gettimeofday()+30, "BOSEST_startDiscoveryProcess", $hash, 0);
    }
    
    return undef;
}

sub BOSEST_Attribute($$$$) {
    my ($mode, $devName, $attrName, $attrValue) = @_;
    
    if($mode eq "set") {
        if(substr($attrName, 0, 8) eq "channel_") {
            #check if there are 3 | in the attrValue
            my @value = split("\\|", $attrValue);
            return "BOSEST: wrong format" if(!defined($value[2]));
            #update reading for channel_X
            readingsSingleUpdate($main::defs{$devName}, $attrName, $value[0], 1);
        } elsif($attrName eq "ttsDLNAServer") {
            BOSEST_addDLNAServer($main::defs{$devName}, $attrValue);
        }
    } elsif($mode eq "del") {
        if(substr($attrName, 0, 8) eq "channel_") {
            #update reading for channel_X
            readingsSingleUpdate($main::defs{$devName}, $attrName, "-", 1);
        }
    }
    
    return undef;
}

sub BOSEST_Set($@) {
    my ($hash, $name, @params) = @_;
    my $workType = shift(@params);
    
    #get quoted text from params
    my $blankParams = join(" ", @params);
    my @params2;
    while($blankParams =~ /"?((?<!")\S+(?<!")|[^"]+)"?\s*/g) {
        push(@params2, $1);
    }
    @params = @params2;

    my $list = "on:noArg off:noArg power:noArg play:noArg 
                mute:on,off,toggle recent source:".$hash->{helper}{supportedSourcesCmds}." 
                nextTrack:noArg prevTrack:noArg playTrack speak speakOff 
                playEverywhere:noArg stopPlayEverywhere:noArg createZone addToZone removeFromZone 
                clock:enable,disable 
                stop:noArg pause:noArg channel:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 
                volume:slider,0,1,100 ".$hash->{helper}{supportedBassCmds}." 
                saveChannel:07,08,09,10,11,12,13,14,15,16,17,18,19,20 
                addDLNAServer:".$hash->{helper}{dlnaServers}." 
                removeDLNAServer:".ReadingsVal($hash->{NAME}, "connectedDLNAServers", "noArg");

    # check parameters for set function
    #DEVELOPNEWFUNCTION-1
    if($workType eq "?") {
        if($hash->{DEVICEID} eq "0") {
            return ""; #no arguments for server
        } else {
            return SetExtensions($hash, $list, $name, $workType, @params);
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
    } elsif($workType eq "saveChannel") {
        return "BOSEST: saveChannel requires channel number as additional parameter" if(int(@params) < 1);
        #params[09 = channel number (07-20)
        BOSEST_saveChannel($hash, $params[0]);
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
    } elsif($workType eq "addDLNAServer") {
        return "BOSEST: addDLNAServer requires DLNA friendly name as additional parameter" if(int(@params) < 1);
        #params[0] = friendly name
        BOSEST_addDLNAServer($hash, $params[0]);
    } elsif($workType eq "removeDLNAServer") {
        return "BOSEST: removeDLNAServer requires DLNA friendly name as additional parameter" if(int(@params) < 1);
        #params[0] = friendly name
        BOSEST_removeDLNAServer($hash, $params[0]);
    } elsif($workType eq "clock") {
        return "BOSEST: clock requires enable/disable as additional parameter" if(int(@params) < 1);
        #check if supported
        return "BOSEST: clock not supported." if(ReadingsVal($hash->{NAME}, "supportClockDisplay", "false") eq "false");
        BOSEST_clockSettings($hash, $params[0]);
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
    } elsif($workType eq "speak" or $workType eq "speakOff") {
        return "BOSEST: speak requires quoted text as additional parameters" if(int(@params) < 1);
        return "BOSEST: speak requires quoted text" if(substr($blankParams, 0, 1) ne "\"");
        return "BOSEST: speak maximum text length is 100 characters" if(length($params[0])>100);
        if(AttrVal($hash->{NAME}, "ttsDirectory", "") eq "") {
            return "BOSEST: Please set ttsDirectory attribute first.
                            FHEM user needs permissions to write to that directory.
                            It is also recommended to set ttsLanguage (default: en).";
        }
        #set text (must be within quotes)
        my $text = $params[0];
        my $volume = "";
        if(looks_like_number($params[1])) {
            #set volume (default current volume)
            $volume = $params[1] if(defined($params[1]));
        } else {
            #parameter is language
            $params[2] = $params[1];
        }
        #set language (default English)
        my $lang = "";
        $lang = $params[2] if(defined($params[2]));
        #stop after speak?
        my $stopAfterSpeak = 0;
        if($workType eq "speakOff") {
            $stopAfterSpeak = 1;
        }
        BOSEST_speak($hash, $text, $volume, $lang, $stopAfterSpeak);
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
        return SetExtensions($hash, $list, $name, $workType, @params);
    }
    
    return undef;
}

#DEVELOPNEWFUNCTION-2 (create own function)
sub BOSEST_clockSettings($$) {
    my ($hash, $val) = @_;
    
    if($val eq "disable") {
        $val = "false";
    } else {
        $val = "true";
    }
    
    my $postXml = "<clockDisplay><clockConfig userEnable=\"$val\"/></clockDisplay>";
    if(BOSEST_HTTPPOST($hash, '/clockDisplay', $postXml)) {
        #readingsSingleUpdate($hash, "bass", $bass+10, 1);
    }
    #FIXME error handling
    
    return undef;
}

sub BOSEST_addDLNAServer($$) {
    my ($hash, $friendlyName) = @_;
    
    #retrieve uuid for friendlyname
    my $listMediaServers = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/listMediaServers");
    foreach my $mediaServer (@{ $listMediaServers->{ListMediaServersResponse}->{media_server} }) {
        $mediaServer->{friendly_name} =~ s/\ /_/g;
        if($mediaServer->{friendly_name} eq $friendlyName) {
            BOSEST_setMusicServiceAccount($hash, $friendlyName, $mediaServer->{id});
        }
    }
    
    return undef;
}

sub BOSEST_removeDLNAServer($$) {
    my ($hash, $friendlyName) = @_;
    
    #retrieve uuid for friendlyname
    my $sources = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/sources");
    foreach my $source (@{ $sources->{sources}->{sourceItem} }) {
        next if($source->{source} ne "STORED_MUSIC");
        
        $source->{content} =~ s/\ /_/g;
        
        if($source->{content} eq $friendlyName) {
            BOSEST_removeMusicServiceAccount($hash, $friendlyName, $source->{sourceAccount});
        }
    }
    
    return undef;
}

sub BOSEST_saveChannel($$) {
    my ($hash, $channel) = @_;

    if(ReadingsVal($hash->{NAME}, "state", "stopped") ne "playing") {
        return "BOSEST: No playing channel. Start a channel and save afterwards.";
    }

    #itemname, location, source, sourceaccount
    my $itemName = ReadingsVal($hash->{NAME}, "contentItemItemName", "");
    my $location = ReadingsVal($hash->{NAME}, "contentItemLocation", "");
    my $source = ReadingsVal($hash->{NAME}, "contentItemSource", "");
    my $sourceAccount = ReadingsVal($hash->{NAME}, "contentItemSourceAccount", "");

    fhem("attr $hash->{NAME} channel_$channel $itemName|$location|$source|$sourceAccount");
    return undef;
}

sub BOSEST_stopPlayEverywhere($) {
    my ($hash) = @_;
    my $postXmlHeader = "<zone master=\"$hash->{DEVICEID}\">";
    my $postXmlFooter = "</zone>";
    my $postXml = "";
    
    my @players = BOSEST_getAllBosePlayers($hash);
    foreach my $playerHash (@players) {
        if($playerHash->{DEVICEID} ne $hash->{DEVICEID}) {
            $postXml .= "<member ipaddress=\"".$playerHash->{helper}{IP}."\">".$playerHash->{DEVICEID}."</member>" if($playerHash->{helper}{IP} ne "unknown");
        }
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
    my $postXml = "<bass>$bass</bass>";
    if(BOSEST_HTTPPOST($hash, '/bass', $postXml)) {
        #readingsSingleUpdate($hash, "bass", $bass+10, 1);
    }
    #FIXME error handling
    return undef;
}

sub BOSEST_setVolume($$) {
    my ($hash, $volume) = @_;

    if(substr($volume, 0, 1) eq "+" or
       substr($volume, 0, 1) eq "-") {
        $volume = ReadingsVal($hash->{NAME}, "volume", 0) + $volume;
    }

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
    
    return undef;
}

sub BOSEST_Get($$) {
    return undef;
}

sub BOSEST_speakChannel {
    my ($hash) = @_;
    
    my $speakChannel = AttrVal($hash->{NAME}, "speakChannel", "");
    if($speakChannel ne "") {
        my $channelNr = ReadingsVal($hash->{NAME}, "channel", "");
        if($channelNr =~ /[$speakChannel]/g) {
            my $channelName = ReadingsVal($hash->{NAME}, "contentItemItemName", "");
            if($channelNr ne "" && $channelName ne "" && $hash->{helper}{lastSpokenChannel} ne $channelName) {
                #speak channel name
                $hash->{helper}{lastSpokenChannel} = $channelName;
                BOSEST_speak($hash, $channelName, "", "", 0);
            }
        } else {
            if($channelNr ne "") {
                #delete lastSpokenChannel
                $hash->{helper}{lastSpokenChannel} = "";
            }
        }
    }
}

sub BOSEST_speak($$$$$) {
    my ($hash, $text, $volume, $lang, $stopAfterSpeak) = @_;
    
    my $ttsDir = AttrVal($hash->{NAME}, "ttsDirectory", "");
    $lang = AttrVal($hash->{NAME}, "ttsLanguage", "en") if($lang eq "");
    $volume = AttrVal($hash->{NAME}, "ttsVolume", ReadingsVal($hash->{NAME}, "volume", 20)) if($volume eq "");
    
    #download file and play
    BOSEST_playGoogleTTS($hash, $ttsDir, $text, $volume, $lang, $stopAfterSpeak);
    
    return undef;
}

sub BOSEST_saveCurrentState($) {
    my ($hash) = @_;
    
    $hash->{helper}{savedState}{volume} = ReadingsVal($hash->{NAME}, "volume", 20);
    $hash->{helper}{savedState}{source} = ReadingsVal($hash->{NAME}, "source", "");
    $hash->{helper}{savedState}{bass} = ReadingsVal($hash->{NAME}, "bass", "");
    $hash->{helper}{savedState}{contentItemItemName} = ReadingsVal($hash->{NAME}, "contentItemItemName", "");
    $hash->{helper}{savedState}{contentItemLocation} = ReadingsVal($hash->{NAME}, "contentItemLocation", "");
    $hash->{helper}{savedState}{contentItemSource} = ReadingsVal($hash->{NAME}, "contentItemSource", "");
    $hash->{helper}{savedState}{contentItemSourceAccount} = ReadingsVal($hash->{NAME}, "contentItemSourceAccount", "");
    
    return undef;
}

sub BOSEST_restoreSavedState($) {
    my ($hash) = @_;
    
    BOSEST_setVolume($hash, $hash->{helper}{savedState}{volume});
    BOSEST_setBass($hash, $hash->{helper}{savedState}{bass});
    
    #bose off when source was off
    if($hash->{helper}{savedState}{source} eq "STANDBY") {
        BOSEST_off($hash);
    } else {
        BOSEST_setContentItem($hash, $hash->{helper}{savedState}{contentItemItemName},
                              $hash->{helper}{savedState}{contentItemLocation},
                              $hash->{helper}{savedState}{contentItemSource},
                              $hash->{helper}{savedState}{contentItemSourceAccount});
    }

    return undef;
}

sub BOSEST_restoreVolumeAndOff($) {
    my ($hash) = @_;

    BOSEST_setVolume($hash, $hash->{helper}{savedState}{volume});
    BOSEST_setBass($hash, $hash->{helper}{savedState}{bass});

    BOSEST_setContentItem($hash, $hash->{helper}{savedState}{contentItemItemName},
                  $hash->{helper}{savedState}{contentItemLocation},
                  $hash->{helper}{savedState}{contentItemSource},
                  $hash->{helper}{savedState}{contentItemSourceAccount});

    BOSEST_off($hash);
}

sub BOSEST_downloadGoogleNotAvailable($) {
    my ($hash) = @_;
    my $text = $BOSEST_GOOGLE_NOT_AVAILABLE_TEXT;
    my $lang = $BOSEST_GOOGLE_NOT_AVAILABLE_LANG;
    my $ttsDir = AttrVal($hash->{NAME}, "ttsDirectory", "");

    my $md5 = md5_hex($lang.$text);
    my $filename = $ttsDir."/".$md5.".mp3";
    if (-f $filename) {
        #file exists already
        return undef;
    }
    
    BOSEST_downloadGoogleTTS($hash, $filename, $md5, $text, $lang);
    
    return undef;
}

sub BOSEST_downloadGoogleTTS($$$$$;$) {
    my ($hash, $filename, $md5, $text, $lang, $callback) = @_;
    
    $hash->{helper}{useragent}->get("http://translate.google.com/translate_tts?tl=$lang&client=tw-ob&q=$text" => sub {
            my ($ua, $tx) = @_;
            my $downloadOk = 0;
            if($tx->res->headers->content_type eq "audio/mpeg") {
                $tx->res->content->asset->move_to($filename);
                $downloadOk = 1;
            }
            if(defined($callback)) {
                $callback->($hash, $filename, $md5, $downloadOk);
            }
    });
    
    return undef;
}

sub BOSEST_playMessage($$$$) {
    my ($hash, $trackname, $volume, $stopAfterSpeak) = @_;
    
    BOSEST_saveCurrentState($hash);
    
    if($volume ne ReadingsVal($hash->{NAME}, "volume", 0)) {
        BOSEST_stop($hash);
        BOSEST_setVolume($hash, $volume);
    }
    
    BOSEST_playTrack($hash, $trackname);
        
    $hash->{helper}{stateCheck}{enabled} = 1;
    $hash->{helper}{stateCheck}{always} = 0;
    #after play the speaker sets INVALID_SOURCE
    $hash->{helper}{stateCheck}{actionSource} = "INVALID_SOURCE";
    #check if we need to stop after speak
    if(defined($stopAfterSpeak) && $stopAfterSpeak eq "1") {
        $hash->{helper}{stateCheck}{function} = \&BOSEST_restoreVolumeAndOff;
    } else {
        $hash->{helper}{stateCheck}{function} = \&BOSEST_restoreSavedState;
    }

    return undef;
}

sub BOSEST_playGoogleTTS($$$$$$) {
    my ($hash, $ttsDir, $text, $volume, $lang, $stopAfterSpeak) = @_;
    
    BOSEST_downloadGoogleNotAvailable($hash);

    my $md5 = md5_hex($lang.$text);
    my $filename = $ttsDir."/".$md5.".mp3";
    
    if(-f $filename) {
        my $timestamp = (stat($filename))->mtime(); #last modification timestamp
        my $now = time();
        if($now-$timestamp < 2592000) {
            #file is not older than 30 days
            #file exists, call play sub
            BOSEST_playMessage($hash, $md5, $volume, $stopAfterSpeak);
            return undef;
        }
    }
    
    BOSEST_downloadGoogleTTS($hash, $filename, $md5, $text, $lang, sub {
            my ($hash, $filename, $md5, $downloadOk) = @_;
            
            if($downloadOk) {
                BOSEST_playMessage($hash, $md5, $volume, $stopAfterSpeak);
            } else {
                if(AttrVal($hash->{NAME}, "ttsSpeakOnError", "1") eq "1") {
                    $md5 = md5_hex($BOSEST_GOOGLE_NOT_AVAILABLE_LANG.$BOSEST_GOOGLE_NOT_AVAILABLE_TEXT);
                    BOSEST_playMessage($hash, $md5, $volume, $stopAfterSpeak);
                } else {
                    Log3 $hash, 3, "BOSEST: Download Google Translate failed ($text).";
                    return undef;
                }
            }
        });
    
    return undef;
}

sub BOSEST_setMusicServiceAccount($$$) {
    my ($hash, $friendlyName, $uuid) = @_;
    my $postXml = '<credentials source="STORED_MUSIC" displayName="'.
                  $friendlyName.
                  '"><user>'.
                  $uuid.'/0'.
                  '</user><pass/></credentials>';
    if(BOSEST_HTTPPOST($hash, '/setMusicServiceAccount', $postXml)) {
        #ok
    }
    return undef;
}

sub BOSEST_removeMusicServiceAccount($$$) {
    my ($hash, $friendlyName, $uuid) = @_;
    my $postXml = '<credentials source="STORED_MUSIC" displayName="'.
                  $friendlyName.
                  '"><user>'.
                  $uuid.
                  '</user><pass/></credentials>';
    if(BOSEST_HTTPPOST($hash, '/removeMusicServiceAccount', $postXml)) {
        #ok
    }
    return undef;
}

sub BOSEST_playTrack($$) {
    my ($hash, $trackName) = @_;

    my $ttsDlnaServer = AttrVal($hash->{NAME}, "ttsDLNAServer", "");
    
    foreach my $source (@{$hash->{helper}{sources}}) {
        if($source->{source} eq "STORED_MUSIC" && $source->{status} eq "READY") {
            #skip servers which don't equal to ttsDLNAServer attribute if set
            if($ttsDlnaServer ne "") {
                next if($ttsDlnaServer ne $source->{content});
            }
            Log3 $hash, 4, "BOSEST: Search for $trackName on $source->{source}";
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
sub BOSEST_updateClock($$) {
    my ($hash, $deviceId) = @_;
    my $clockDisplay = BOSEST_HTTPGET($hash, $hash->{helper}{IP}, "/clockDisplay");
    BOSEST_processXml($hash, $clockDisplay);
    return undef;
}

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
    
    return undef if($channel eq "");
    
    if(!defined($hash->{helper}{dt_nowSelectionUpdatedTS}) or $channel ne $hash->{helper}{dt_nowSelectionUpdatedCH}) {
        $hash->{helper}{dt_nowSelectionUpdatedTS} = gettimeofday();
        $hash->{helper}{dt_nowSelectionUpdatedCH} = $channel;
        $hash->{helper}{dt_lastChange} = 0;
        $hash->{helper}{dt_counter} = 1;
        return undef;
    }
    
    my $timeDiff = gettimeofday() - $hash->{helper}{dt_nowSelectionUpdatedTS};
    if($timeDiff < 1) {
        $hash->{helper}{dt_counter}++;
        
        if($hash->{helper}{dt_counter} == 2) {
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
        } elsif($hash->{helper}{dt_counter} == 3) {
            #handle three-tap function - ideas?
        }
    } else {
        $hash->{helper}{dt_counter} = 1;
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
                } else {
                    BOSEST_speakChannel($hash);
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
        } elsif ($wsxml->{updates}->{clockTimeUpdated}) {
            BOSEST_parseAndUpdateClock($hash, $wsxml->{updates}->{clockTimeUpdated});
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
    } else {
        Log3 $hash, 4, "BOSEST: Unknown event, please implement:\n".Dumper($wsxml);
    }
    
    if($hash->{helper}{stateCheck}{enabled}) {
        #check if state is action state
        if(ReadingsVal($hash->{NAME}, "source", "") eq $hash->{helper}{stateCheck}{actionSource}) {
            #call function with $hash as argument
            $hash->{helper}{stateCheck}{function}->($hash);
            
            #reset if always is not enabled
            if(!$hash->{helper}{stateCheck}{always}) {
                $hash->{helper}{stateCheck}{enabled} = 0;
            }
        }
    }
    
    return undef;
}

sub BOSEST_parseAndUpdateClock($$) {
    my ($hash, $clock) = @_;
    
    if($clock->{clockTime}->{brightness} eq "0") {
        readingsSingleUpdate($hash, "clockDisplay", "off", 1);
    } else {
        readingsSingleUpdate($hash, "clockDisplay", "on", 1);
    }
    
    return undef;
}

sub BOSEST_parseAndUpdateSources($$) {
    my ($hash, $sourceItems) = @_;
    
    $hash->{helper}->{sources} = ();
    
    foreach my $sourceItem (@{$sourceItems}) {
        Log3 $hash, 5, "BOSEST: Add $sourceItem->{source}";
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
    
    my $connectedDlnaServers = "";
    foreach my $sourceItem (@{ $hash->{helper}->{sources} }) {
        if($sourceItem->{source} eq "STORED_MUSIC") {
            $connectedDlnaServers .= $sourceItem->{name}.",";
        }
    }
    #remove last comma
    $connectedDlnaServers = substr($connectedDlnaServers, 0, length($connectedDlnaServers) - 1);
    #replace blank with hyphen
    $connectedDlnaServers =~ s/\ /_/g;
    
    readingsSingleUpdate($hash, "connectedDLNAServers", $connectedDlnaServers, 1);
    
    return undef;
}

sub BOSEST_parseAndUpdateChannel($$) {
    my ($hash, $preset) = @_;
    
    readingsBeginUpdate($hash);
    if($preset->{id} ne "0") {
        BOSEST_XMLUpdate($hash, "channel", $preset->{id});
    } else {
        BOSEST_XMLUpdate($hash, "channel", "");
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
        last if($i > 15);
    }
    
    foreach my $x ($i..15) {
        BOSEST_XMLUpdate($hash, sprintf("recent_%02d", $x), "-");
        delete $hash->{helper}{recents}{$x};
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
            my $sources = BOSEST_HTTPGET($hash, $device->address, "/sources");
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

            #MOVE THIS PART INTO THE IF ABOVE IN FOR NEXT VERSION
            #set supported sources
            $return .= "|supportedSources|$info->{deviceID}";
            foreach my $source (@{ $sources->{sources}->{sourceItem} }) {
                $return .= ",".$source->{source};
            }

            #set supported capabilities
            my $capabilities = BOSEST_HTTPGET($hash, $device->address, "/capabilities");
            $return .= "|capabilities|$info->{deviceID}";
            if($capabilities->{capabilities}->{clockDisplay}) {
                $return .= ",".$capabilities->{capabilities}->{clockDisplay};
            } else {
                $return .= ",false";
            }

            #set supported bass capabilities
            my $bassCapabilities = BOSEST_HTTPGET($hash, $device->address, "/bassCapabilities");
            $return .= "|bassCapabilities|$info->{deviceID}";
            if($bassCapabilities->{bassCapabilities}) {
                my $bassCap = $bassCapabilities->{bassCapabilities};
                $return .= ",".$bassCap->{bassAvailable}.",".$bassCap->{bassMin}.",".
                           $bassCap->{bassMax}.",".$bassCap->{bassDefault};
            }

            #TODO create own function
            my $myIp = BOSEST_getMyIp($hash);
            my $listMediaServers = BOSEST_HTTPGET($hash, $device->address, "/listMediaServers");

            my $returnListMediaServers = "|listMediaServers|".$info->{deviceID};
            foreach my $mediaServer (@{ $listMediaServers->{ListMediaServersResponse}->{media_server} }) {
                $returnListMediaServers .= ",".$mediaServer->{friendly_name};
                
                #check if it is already connected
                my $isConnected = 0;
                foreach my $source (@{ $sources->{sources}->{sourceItem} }) {
                    next if($source->{source} ne "STORED_MUSIC");
                    
                    if(substr($source->{sourceAccount}, 0, length($mediaServer->{id})) eq $mediaServer->{id}) {
                        #already connected
                        $isConnected = 1;
                        next;
                    }
                }
                
                next if($isConnected);
                
                if(($myIp eq $mediaServer->{ip}) ||
                   (AttrVal($name, "autoAddDLNAServers", "0") eq "1" )) {
                    $return = $return."|setMusicServiceAccount|".$info->{deviceID}.",".$mediaServer->{friendly_name}.",".$mediaServer->{id};
                    Log3 $hash, 3, "BOSEST: DLNA Server ".$mediaServer->{friendly_name}." added.";
                }
            }
            
            #append listMediaServers
            $return .= $returnListMediaServers;

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
        my $deviceId = shift(@params);
        
        next if($ignoreDeviceIDs =~ /$deviceId/);

        if($command eq "commandDefineBOSE") {
            my $deviceName = $params[0];
            BOSEST_commandDefine($hash, $deviceId, $deviceName);
        } elsif($command eq "updateIP") {
            my $ip = $params[0];
            BOSEST_updateIP($hash, $deviceId, $ip);
        } elsif($command eq "setMusicServiceAccount") {
            my $deviceHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceId);
            #0...friendly name
            #1...UUID
            BOSEST_setMusicServiceAccount($deviceHash, $params[0], $params[1]);
        } elsif($command eq "listMediaServers") {
            my $deviceHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceId);
            $deviceHash->{helper}{dlnaServers} = join(",", @params);
            $deviceHash->{helper}{dlnaServers} =~ s/\ /_/g;
        } elsif($command eq "bassCapabilities") {
            my $deviceHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceId);
            #bassAvailable, bassMin, bassMax, bassDefault
            $deviceHash->{helper}{bassAvailable} = 1 if($params[0] eq "true");
            $deviceHash->{helper}{bassMin} = $params[1];
            $deviceHash->{helper}{bassMax} = $params[2];
            $deviceHash->{helper}{bassDefault} = $params[3];
            if($params[0] eq "true") {
                $deviceHash->{helper}{supportedBassCmds} = "bass:slider,1,1,10";
            } else {
                $deviceHash->{helper}{supportedBassCmds} = "";
            }
        } elsif($command eq "supportedSources") {
            my $deviceHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceId);
            #list of supported sources
            $deviceHash->{helper}{bluetoothSupport} = 0;
            $deviceHash->{helper}{auxSupport} = 0;
            $deviceHash->{helper}{airplaySupport} = 0;
            $deviceHash->{helper}{supportedSourcesCmds} = "";
            foreach my $source (@params) {
                if($source eq "BLUETOOTH") {
                    $deviceHash->{helper}{bluetoothSupport} = 1;
                    $deviceHash->{helper}{supportedSourcesCmds} .= "bluetooth,bt-discover,";
                } elsif($source eq "AUX") {
                    $deviceHash->{helper}{auxSupport} = 1;
                    $deviceHash->{helper}{supportedSourcesCmds} .= "aux,";
                } elsif($source eq "AIRPLAY") {
                    $deviceHash->{helper}{airplaySupport} = 1;
                    $deviceHash->{helper}{supportedSourcesCmds} .= "airplay,";
                }
            } 
            $deviceHash->{helper}{supportedSourcesCmds} = substr($deviceHash->{helper}{supportedSourcesCmds}, 0, length($deviceHash->{helper}{supportedSourcesCmds})-1);
        } elsif($command eq "capabilities") {
            my $deviceHash = BOSEST_getBosePlayerByDeviceId($hash, $deviceId);
            readingsSingleUpdate($deviceHash, "supportClockDisplay", $params[0], 1);
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
        #get current clock state
        BOSEST_updateClock($deviceHash, $deviceID);
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
        $xml = XMLin($msg, KeepRoot => 1, ForceArray => [qw(media_server item member recent)], KeyAttr => []);
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
sub BOSEST_getMyIp($) {
    #Attention: Blocking function
    my ($hash) = @_;

    my $socket = IO::Socket::INET->new(
        Proto => 'udp',
        PeerAddr => '198.41.0.4', #a.root-servers.net
        PeerPort => '53' #DNS
    );

    my $local_ip_address = $socket->sockhost;

    return $local_ip_address;
}

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
            $xmlres = XMLin($response->decoded_content, KeepRoot => 1, ForceArray => [qw(media_server item member recent)], KeyAttr => []);
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
            $xmlres = XMLin($response->decoded_content, KeepRoot => 1, ForceArray => [qw(media_server item member recent)], KeyAttr => []);
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
      Defines BOSE SoundTouch system. All devices/speakers will show up after 60s under "Unsorted" in FHEM.<br/>
    </ul>
	</ul>
  
  <br>

  <a name="BOSESTset" id="BOSESTset"></a>
  <b>Set</b>
 		<ul>
    <code>set &lt;name&gt; &lt;command&gt; [&lt;parameter&gt;]</code><br>
               The following commands are defined for the devices/speakers (execpt <b>autoAddDLNAServers</b> is for the "main" BOSEST) :<br><br>
        <ul><u>General commands</u>
          <li><code><b>on</b></code> &nbsp;&nbsp;-&nbsp;&nbsp; power on the device</li>
          <li><code><b>off</b></code> &nbsp;&nbsp;-&nbsp;&nbsp; turn the device off</li>          
          <li><code><b>power</b></code> &nbsp;&nbsp;-&nbsp;&nbsp; toggle on/off</li>
          <li><code><b>volume</b> [0...100] [+x|-x]</code> &nbsp;&nbsp;-&nbsp;&nbsp; set the volume level in percentage or change volume by ±x from current level</li>
          <li><code><b>channel</b> 0...20</code> &nbsp;&nbsp;-&nbsp;&nbsp; select present to play</li>
          <li><code><b>saveChannel</b> 07...20</code> &nbsp;&nbsp;-&nbsp;&nbsp; save current channel to channel 07 to 20</li>
          <li><code><b>play</b></code> &nbsp;&nbsp;-&nbsp;&nbsp; start/resume to play </li>
          <li><code><b>pause</b></code> &nbsp;&nbsp;-&nbsp;&nbsp; pause the playback</li>
          <li><code><b>stop</b></code> &nbsp;&nbsp;-&nbsp;&nbsp; stop playback</li>
          <li><code><b>nextTrack</b></code> &nbsp;&nbsp;-&nbsp;&nbsp; play next track</li>
          <li><code><b>prevTrack</b></code> &nbsp;&nbsp;-&nbsp;&nbsp; play previous track</li>
          <li><code><b>mute</b> on|off|toggle</code> &nbsp;&nbsp;-&nbsp;&nbsp; control volume mute</li>
          <li><code><b>bass</b> 0...10</code> &nbsp;&nbsp;-&nbsp;&nbsp; set the bass level</li>
          <li><code><b>recent</b> 0...15</code> &nbsp;&nbsp;-&nbsp;&nbsp; set number of names in the recent list in readings</li>
          <li><code><b>source</b> bluetooth,bt-discover,aux mode, airplay</code> &nbsp;&nbsp;-&nbsp;&nbsp; select a local source</li><br>
          <li><code><b>addDLNAServer</b> Name1 [Name2] [Namex]</code> &nbsp;&nbsp;-&nbsp;&nbsp; add DLNA servers Name1 (and Name2 to Namex) to the BOSE library</li>
          <li><code><b>removeDLNAServer</b> Name1 [Name2] [Namex]</code> &nbsp;&nbsp;-&nbsp;&nbsp; remove DLNA servers Name1 (and Name2 to Namex) to the BOSE library</li>
         </ul><br>Example: <code>set BOSE_1234567890AB volume 25</code>&nbsp;&nbsp;Set volume on device with the name BOSE_1234567890AB <br><br><br>  
         	
         <ul><u>Timer commands:</u>        
          <li><code><b>on-for-timer</b> 1...x</code> &nbsp;&nbsp;-&nbsp;&nbsp; power on the device for x seconds</li>
          <li><code><b>off-for-timer</b> 1...x</code> &nbsp;&nbsp;-&nbsp;&nbsp; turn the device off and power on again after x seconds</li>
          <li><code><b>on-till</b> hh:mm:ss</code> &nbsp;&nbsp;-&nbsp;&nbsp; power on the device until defined time</li>
          <li><code><b>off-till</b> hh:mm:ss</code> &nbsp;&nbsp;-&nbsp;&nbsp; turn the device off and power on again at defined time</li>
          <li><code><b>on-till-overneight</b> hh:mm:ss</code> &nbsp;&nbsp;-&nbsp;&nbsp; power on the device until defined time on the next day</li>
          <li><code><b>off-till-overneight</b> hh:mm:ss</code> &nbsp;&nbsp;-&nbsp;&nbsp; turn the device off at defined time on the next day</li>
         </ul><br>Example: <code>set BOSE_1234567890AB on-till 23:00:00</code>&nbsp;&nbsp;Switches device with the name BOSE_1234567890AB now on and at 23:00:00 off<br><br><br>
         	
         <ul><u>Multiroom commands:</u>
          <li><code><b>createZone</b> deviceID</code> &nbsp;&nbsp;-&nbsp;&nbsp; create multiroom zone (defines <code>&lt;name&gt;</code> as zoneMaster) </li>          
          <li><code><b>addToZone</b> deviceID</code> &nbsp;&nbsp;-&nbsp;&nbsp; add device <code>&lt;name&gt;</code> to multiroom zone</li>
          <li><code><b>removeFromZone</b> deviceID</code> &nbsp;&nbsp;-&nbsp;&nbsp; remove device <code>&lt;name&gt;</code> from multiroom zone</li>
          <li><code><b>playEverywhere</b></code>  &nbsp;&nbsp;-&nbsp;&nbsp; play sound of  device <code>&lt;name&gt;</code> on all others devices</li>
          <li><code><b>stopPlayEverywhere</b></code>  &nbsp;&nbsp;-&nbsp;&nbsp; stop playing sound on all devices</li>
        </ul><br>Example: <code>set BOSE_1234567890AB playEverywhere</code>&nbsp;&nbsp;Starts Multiroom with device with the name BOSE_1234567890AB as master <br><br><br>
        	
        <ul><u>TextToSpeach commands (needs Google Translate):</u>
         <li><code><b>speak</b> "message" [0...100] [+x|-x] [en|de|xx]</code> &nbsp;&nbsp;-&nbsp;&nbsp; Text to speak, optional with volume adjustment and language to use. The message to speak may have up to 100 letters</li>
         <li><code><b>speakOff</b> "message" [0...100] [+x|-x] [en|de|xx]</code> &nbsp;&nbsp;-&nbsp;&nbsp; Text to speak, optional with volume adjustment and language to use. The message to speak may have up to 100 letters. Device is switched off after speak</li>
         <li><code><b>ttsVolume</b> [0...100] [+x|-x]</code> &nbsp;&nbsp;-&nbsp;&nbsp; set the TTS volume level in percentage or change volume by ±x from current level</li>
         <li><code><b>ttsDLNAServer</b> "DLNA Server"</code> &nbsp;&nbsp;-&nbsp;&nbsp;  set DLNA TTS server, only needed if the DLNA server is not the FHEM server, a DLNA server running on the same server as FHEM is automatically added to the BOSE library</li>            
         <li><code><b>ttsDirectory</b> "directory"</code> &nbsp;&nbsp;-&nbsp;&nbsp; set DLNA TTS directory. FHEM user needs permissions to write to that directory. </li>  
         <li><code><b>ttsLanguage </b> en|de|xx</code> &nbsp;&nbsp;-&nbsp;&nbsp; set default TTS language (default: en)</li> 
         <li><code><b>ttsSpeakOnError</b> 0|1</code> &nbsp;&nbsp;-&nbsp;&nbsp; 0=disable to speak "not available" text</li> 
         <li><code><b>autoAddDLNAServers</b> 0|1</code> &nbsp;&nbsp;-&nbsp;&nbsp; 1=automatically add all DLNA servers to BOSE library. This command is only for "main" BOSEST, not for devices/speakers!</li> <br>
        </ul><br> Example: <code>set BOSE_1234567890AB speakOff "Music is going to switch off now. Good night." 30 en</code>&nbsp;&nbsp;Speaks message at volume 30 and then switches off device.<br><br> <br>
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

