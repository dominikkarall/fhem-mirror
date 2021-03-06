##############################################
# $Id$
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use ZWLib;

sub ZWDongle_Parse($$$);
sub ZWDongle_Read($@);
sub ZWDongle_ReadAnswer($$$);
sub ZWDongle_Ready($);
sub ZWDongle_Write($$$);
sub ZWDongle_ProcessSendStack($);


# See also:
# http://www.digiwave.dk/en/programming/an-introduction-to-the-z-wave-protocol/
# http://open-zwave.googlecode.com/svn-history/r426/trunk/cpp/src/Driver.cpp
# http://buzzdavidson.com/?p=68
# https://bitbucket.org/bradsjm/aeonzstickdriver
my %sets = (
  "addNode"          => { cmd => "4a%02x@",    # ZW_ADD_NODE_TO_NETWORK'
                          param => { onNw   =>0xc1, on   =>0x81, off=>0x05,
                                     onNwSec=>0xc1, onSec=>0x81 } },
  "removeNode"       => { cmd => "4b%02x@",    # ZW_REMOVE_NODE_FROM_NETWORK'
                          param => {onNw=>0xc1, on=>0x81, off=>0x05 } },
  "createNode"       => { cmd => "60%02x" },   # ZW_REQUEST_NODE_INFO'
  "removeFailedNode" => { cmd => "61%02x@" },   # ZW_REMOVE_FAILED_NODE_ID
  "replaceFailedNode"=> { cmd => "63%02x@" },   # ZW_REPLACE_FAILED_NODE
  "sendNIF"          => { cmd => "12%02x05@" },# ZW_SEND_NODE_INFORMATION
  "setNIF"           => { cmd => "03%02x%02x%02x%02x" },
                                              # SERIAL_API_APPL_NODE_INFORMATION
  "timeouts"         => { cmd => "06%02x%02x" }, # SERIAL_API_SET_TIMEOUTS
  "reopen"           => { cmd => "" },
);

my %gets = (
  "caps"            => "07",      # SERIAL_API_GET_CAPABILITIES
  "ctrlCaps"        => "05",      # ZW_GET_CONTROLLER_CAPS
  "getVirtualNodes" => "a5",      # ZW_GET_VIRTUAL_NODES
  "homeId"          => "20",      # MEMORY_GET_ID
  "isFailedNode"    => "62%02x",  # ZW_IS_FAILED_NODE
  "neighborList"    => "80%02x",  # GET_ROUTING_TABLE_LINE
  "nodeInfo"        => "41%02x",  # ZW_GET_NODE_PROTOCOL_INFO
  "nodeList"        => "02",      # SERIAL_API_GET_INIT_DATA
  "random"          => "1c%02x",  # ZW_GET_RANDOM
  "version"         => "15",      # ZW_GET_VERSION
  "timeouts"        => "06",      # SERIAL_API_SET_TIMEOUTS
  "raw"             => "%s",            # hex
);

sub
ZWDongle_Initialize($)
{
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}  = "ZWDongle_Read";
  $hash->{WriteFn} = "ZWDongle_Write";
  $hash->{ReadyFn} = "ZWDongle_Ready";
  $hash->{ReadAnswerFn} = "ZWDongle_ReadAnswer";

# Normal devices
  $hash->{DefFn}   = "ZWDongle_Define";
  $hash->{SetFn}   = "ZWDongle_Set";
  $hash->{GetFn}   = "ZWDongle_Get";
  $hash->{AttrFn}  = "ZWDongle_Attr";
  $hash->{UndefFn} = "ZWDongle_Undef";
  $hash->{AttrList}= "do_not_notify:1,0 dummy:1,0 model:ZWDongle disable:0,1 ".
                     "homeId networkKey";
}

#####################################
sub
ZWDongle_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    my $msg = "wrong syntax: define <name> ZWDongle {none[:homeId] | ".
                        "devicename[\@baudrate] | ".
                        "devicename\@directio | ".
                        "hostname:port}";
    return $msg;
  }

  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];

  $hash->{Clients} = ":ZWave:";
  my %matchList = ( "1:ZWave" => ".*" );
  $hash->{MatchList} = \%matchList;

  if($dev =~ m/none:(.*)/) {
    $hash->{homeId} = $1;
    Log3 $name, 1, 
        "$name device is none (homeId:$1), commands will be echoed only";
    $attr{$name}{dummy} = 1;
    readingsSingleUpdate($hash, "state", "dummy", 1);
    return undef;

  } elsif($dev !~ m/@/ && $dev !~ m/:/) {
    $def .= "\@115200";  # default baudrate

  }

  $hash->{DeviceName} = $dev;
  $hash->{CallbackNr} = 0;
  $hash->{nrNAck} = 0;
  my @empty;
  $hash->{SendStack} = \@empty;
  ZWDongle_shiftSendStack($hash, 0, 5, undef);
  
  my $ret = DevIo_OpenDev($hash, 0, "ZWDongle_DoInit");
  return $ret;
}

#####################################
sub
ZWDongle_Undef($$) 
{
  my ($hash,$arg) = @_;
  DevIo_CloseDev($hash); 
  return undef;
}

#####################################
sub
ZWDongle_Set($@)
{
  my ($hash, @a) = @_;
  my $name = shift @a;

  return "\"set ZWDongle\" needs at least one parameter" if(@a < 1);
  my $type = shift @a;

  if(!defined($sets{$type})) {
    my @r;
    map { my $p = $sets{$_}{param};
          push @r,($p ? "$_:".join(",",sort keys %{$p}) : $_)} sort keys %sets;
    return "Unknown argument $type, choose one of " . join(" ",@r);
  }

  Log3 $hash, 4, "ZWDongle set $name $type ".join(" ",@a);
  if($type eq "reopen") {
    return if(AttrVal($name, "dummy",undef) || AttrVal($name, "disable",undef));
    delete $hash->{NEXT_OPEN};
    DevIo_CloseDev($hash);
    sleep(1);
    DevIo_OpenDev($hash, 0, "ZWDongle_DoInit");
    return;
  }

  if(($type eq "removeFailedNode" ||
      $type eq "replaceFailedNode" ||
      $type eq "sendNIF") &&
     $defs{$a[0]} && $defs{$a[0]}{nodeIdHex}) {
    $a[0] = hex($defs{$a[0]}{nodeIdHex});
  }

  my $cmd = $sets{$type}{cmd};
  my $fb = substr($cmd, 0, 2);
  if($fb =~ m/^[0-8A-F]+$/i &&
     ReadingsVal($name, "caps","") !~ m/\b$zw_func_id{$fb}\b/) {
    return "$type is unsupported by this controller";
  }

  if($type eq "addNode") {
    if($a[0] && $a[0] =~ m/sec/i) {
      $hash->{addSecure} = 1;
    } else {
      delete($hash->{addSecure});
    }
  }

  my $par = $sets{$type}{param};
  if($par && !$par->{noArg}) {
    return "Unknown argument for $type, choose one of ".join(" ",keys %{$par})
      if(!$a[0] || !defined($par->{$a[0]}));
    $a[0] = $par->{$a[0]};
  }

  if($cmd =~ m/\@/) {
    my $c = $hash->{CallbackNr}+1;
    $c = 1 if($c > 255);
    $hash->{CallbackNr} = $c;
    $c = sprintf("%02x", $c);
    $cmd =~ s/\@/$c/g;
  }


  my @ca = split("%", $cmd, -1);
  my $nargs = int(@ca)-1;
  return "set $name $type needs $nargs arguments" if($nargs != int(@a));

  ZWDongle_Write($hash, "",  "00".sprintf($cmd, @a));
  return undef;
}

#####################################
sub
ZWDongle_Get($@)
{
  my ($hash, @a) = @_;
  my $name = shift @a;

  return "\"get $name\" needs at least one parameter" if(@a < 1);
  my $cmd = shift @a;

  return "Unknown argument $cmd, choose one of " .
        join(" ", map { $gets{$_} =~ m/%/ ? $_ : "$_:noArg" } sort keys %gets)
        if(!defined($gets{$cmd}));

  my $fb = substr($gets{$cmd}, 0, 2);
  if($fb =~ m/^[0-8A-F]+$/i && $cmd ne "caps" &&
     ReadingsVal($name, "caps","") !~ m/\b$zw_func_id{$fb}\b/) {
    return "$cmd is unsupported by this controller";
  }

  Log3 $hash, 4, "ZWDongle get $name $cmd ".join(" ",@a);

  if($cmd eq "neighborList") {
    my @b;
    @b = grep(!/onlyRep/i,  @a); my $onlyRep = (@b != @a); @a = @b;
    @b = grep(!/excludeDead/i,  @a); my $exclDead = (@b != @a); @a = @b;
    $gets{neighborList} = "80%02x".($exclDead ?"00":"01").($onlyRep ?"01":"00");
    return "Usage: get $name $cmd [excludeDead] [onlyRep] nodeId"
        if(int(@a) != 1);
  }

  my @ga = split("%", $gets{$cmd}, -1);
  my $nargs = int(@ga)-1;
  return "get $name $cmd needs $nargs arguments" if($nargs != int(@a));

  return "No $cmd for dummies" if(IsDummy($name));

  if(($cmd eq "neighborList" ||
      $cmd eq "nodeInfo" ||
      $cmd eq "isFailedNode") &&
     $defs{$a[0]} && $defs{$a[0]}{nodeIdHex}) {
    $a[0] = hex($defs{$a[0]}{nodeIdHex});
  }

  my $out = sprintf($gets{$cmd}, @a);
  ZWDongle_Write($hash, "", "00".$out);
  my $re = "^01".substr($out,0,2);  # Start with <01><len><01><CMD>
  my ($err, $ret) = ZWDongle_ReadAnswer($hash, $cmd, $re);
  return $err if($err);

  my $msg="";
  $msg = $ret if($ret);
  my @r = map { ord($_) } split("", pack('H*', $ret)) if(defined($ret));

  if($cmd eq "nodeList") {                     ############################
    $msg =~ s/^.{10}(.{58}).*/$1/;
    $msg = zwlib_parseNeighborList($hash, $msg);

  } elsif($cmd eq "caps") {                    ############################
    $msg  = sprintf("Vers:%d Rev:%d ",       $r[2], $r[3]);
    $msg .= sprintf("ManufID:%02x%02x ",     $r[4], $r[5]);
    $msg .= sprintf("ProductType:%02x%02x ", $r[6], $r[7]);
    $msg .= sprintf("ProductID:%02x%02x",    $r[8], $r[9]);
    my @list;
    for my $byte (0..31) {
      my $bits = $r[10+$byte];
      for my $bit (0..7) {
        my $id = sprintf("%02x", $byte*8+$bit+1);
        push @list, ($zw_func_id{$id} ? $zw_func_id{$id} : "UNKNOWN_$id")
                if($bits & (1<<$bit));
      }
    }
    $msg .= " ".join(" ",@list);

  } elsif($cmd eq "homeId") {                  ############################
    $msg = sprintf("HomeId:%s CtrlNodeId:%s", 
                substr($ret,4,8), substr($ret,12,2));
    $hash->{homeId} = substr($ret,4,8);
    $hash->{nodeIdHex} = substr($ret,12,2);
    $attr{NAME}{homeId} = substr($ret,4,8);

  } elsif($cmd eq "version") {                 ############################
    $msg = join("",  map { chr($_) } @r[2..13]);
    my @type = qw( STATIC_CONTROLLER CONTROLLER ENHANCED_SLAVE
                   SLAVE INSTALLER NO_INTELLIGENT_LIFE BRIDGE_CONTROLLER);
    my $idx = $r[14]-1;
    $msg .= " $type[$idx]" if($idx >= 0 && $idx <= $#type);

  } elsif($cmd eq "ctrlCaps") {                ############################
    my @type = qw(SECONDARY OTHER MEMBER PRIMARY SUC);
    my @list;
    for my $bit (0..7) {
      push @list, $type[$bit] if(($r[2] & (1<<$bit)) && $bit < @type);
    }
    $msg = join(" ", @list);

  } elsif($cmd eq "getVirtualNodes") {         ############################
    $msg = join(" ", @r);

  } elsif($cmd eq "nodeInfo") {                ############################
    my $id = sprintf("%02x", $r[6]);
    if($id eq "00") {
      $msg = "node $a[0] is not present";
    } else {
      $msg = zwlib_parseNodeInfo(@r);
    }

  } elsif($cmd eq "random") {                  ############################
    return "$name: Cannot generate" if($ret !~ m/^011c01(..)(.*)$/);
    $msg = $2; @a = ();

  } elsif($cmd eq "isFailedNode") {            ############################
    $msg = ($r[2]==1)?"yes":"no";

  } elsif($cmd eq "neighborList") {            ############################
    $msg =~ s/^....//;
    $msg = zwlib_parseNeighborList($hash, $msg);

  }

  $cmd .= "_".join("_", @a) if(@a);
  $hash->{READINGS}{$cmd}{VAL} = $msg;
  $hash->{READINGS}{$cmd}{TIME} = TimeNow();

  return "$name $cmd => $msg";
}

#####################################
sub
ZWDongle_Clear($)
{
  my $hash = shift;

  # Clear the pipe
  $hash->{RA_Timeout} = 1.0;
  for(;;) {
    my ($err, undef) = ZWDongle_ReadAnswer($hash, "Clear", "wontmatch");
    last if($err && ($err =~ m/^Timeout/ || $err =~ m/No FD/));
  }
  delete($hash->{RA_Timeout});
  $hash->{PARTIAL} = "";
}

#####################################
sub
ZWDongle_DoInit($)
{
  my $hash = shift;
  my $name = $hash->{NAME};

  DevIo_SetHwHandshake($hash) if($hash->{USBDev});
  $hash->{PARTIAL} = "";
  
  ZWDongle_Clear($hash);
  ZWDongle_Get($hash, $name, "caps");
  ZWDongle_Get($hash, $name, "homeId");
  ZWDongle_Get($hash, $name, ("random", 32));         # Sec relevant
  ZWDongle_Set($hash, $name, ("timeouts", 100, 15));  # Sec relevant
  ZWDongle_ReadAnswer($hash, "timeouts", "^0106");
  # NODEINFO_LISTENING, Generic Static controller, Specific Static Controller, 0
  ZWDongle_Set($hash, $name, ("setNIF", 1, 2, 1, 0)); # Sec relevant (?)

  readingsSingleUpdate($hash, "state", "Initialized", 1);
  return undef;
}

#####################################
sub
ZWDongle_Write($$$)
{
  my ($hash,$fn,$msg) = @_;

  Log3 $hash, 5, "ZWDongle_Write $msg ($fn)";
  # assemble complete message
  $msg = sprintf("%02x%s", length($msg)/2+1, $msg);

  $msg = "01$msg" . zwlib_checkSum_8($msg);
  push @{$hash->{SendStack}}, $msg;

  ZWDongle_ProcessSendStack($hash);
}

sub
ZWDongle_shiftSendStack($$$$)
{
  my ($hash, $reason, $loglevel, $txt) = @_;
  my $ss = $hash->{SendStack};
  my $cmd = $ss->[0];

  if($cmd && $reason==0 && $cmd =~ m/^01..0013/) { # ACK for SEND_DATA
    Log3 $hash, $loglevel, "$txt, WaitForAck=>2 for $cmd"
        if($txt && $cmd);
    $hash->{WaitForAck}=2;

  } else {
    shift @{$ss};
    Log3 $hash, $loglevel, "$txt, removing $cmd from dongle sendstack"
        if($txt && $cmd);
    $hash->{WaitForAck}=0;
    $hash->{SendRetries}=0;
    $hash->{MaxSendRetries}=3;
  }
}

sub
ZWDongle_ProcessSendStack($)
{
  my ($hash) = @_;
    
  #Log3 $hash, 1, "ZWDongle_ProcessSendStack: ".@{$hash->{SendStack}}.
  #                      " items on stack, waitForAck ".$hash->{WaitForAck};
  
  RemoveInternalTimer($hash); 
    
  my $ts = gettimeofday();  

  if($hash->{WaitForAck}){
    if($hash->{WaitForAck} == 1 && $ts-$hash->{SendTime} >= 1) {
      Log3 $hash, 2, "ZWDongle_ProcessSendStack: no ACK, resending message ".
                      $hash->{SendStack}->[0];
      $hash->{SendRetries}++;
      $hash->{WaitForAck} = 0;

    } elsif($hash->{WaitForAck} == 2 && $ts-$hash->{SendTime} >= 2) {
      ZWDongle_shiftSendStack($hash, 1, 4, "no response from device");

    } else {
      InternalTimer($ts+1, "ZWDongle_ProcessSendStack", $hash, 0);
      return;

    }
  }

  if($hash->{SendRetries} > $hash->{MaxSendRetries}){
    ZWDongle_shiftSendStack($hash, 1, 1, "ERROR: max send retries reached");
  }
  
  return if(!@{$hash->{SendStack}} ||
               $hash->{WaitForAck} ||
               !DevIo_IsOpen($hash));
  
  my $msg = $hash->{SendStack}->[0];

  DevIo_SimpleWrite($hash, $msg, 1);
  $hash->{WaitForAck} = 1;
  $hash->{SendTime} = $ts;

  InternalTimer($ts+1, "ZWDongle_ProcessSendStack", $hash, 0);
}

#####################################
# called from the global loop, when the select for hash->{FD} reports data
sub
ZWDongle_Read($@)
{
  my ($hash, $local, $regexp) = @_;

  my $buf = (defined($local) ? $local : DevIo_SimpleRead($hash));
  return "" if(!defined($buf));

  my $name = $hash->{NAME};

  $buf = unpack('H*', $buf);
  # The dongle looses data over USB for some commands(?), and dropping the old
  # buffer after a timeout is my only idea of solving this problem.
  my $ts   = gettimeofday();
  my $data = ($hash->{ReadTime} && $ts-$hash->{ReadTime} > 1) ?
                        $buf : $hash->{PARTIAL}.$buf;
  $hash->{ReadTime} = $ts;


  #Log3 $name, 5, "ZWDongle RAW buffer: $data";

  my $msg;
  while(length($data) > 0) {

    my $fb = substr($data, 0, 2);

    if($fb eq "06") {   # ACK
      ZWDongle_shiftSendStack($hash, 0, 5, "ACK received");
      $data = substr($data, 2);
      next;
    }

    if($fb eq "15") {   # NACK
      Log3 $name, 4, "ZWDongle_Read $name: NACK received";
      $hash->{WaitForAck} = 0;
      $hash->{SendRetries}++;
      $data = substr($data, 2);
      next;
    }

    if($fb eq "18") {   # CAN
      Log3 $name, 4, "ZWDongle_Read $name: CAN received";
      $hash->{MaxSendRetries}++ if($hash->{MaxSendRetries}<7);
      $data = substr($data, 2);
      if(!$init_done) { # InternalTimer wont work
        $hash->{WaitForAck} = 0;
        $hash->{SendRetries}++;
        select(undef, undef, undef, 0.1);
      }
      next;
    }

    if($fb ne "01") {   # SOF
      Log3 $name, 1, "$name: SOF missing (got $fb instead of 01)";
      if(++$hash->{nrNAck} < 5){
        Log3 $name, 5, "ZWDongle_Read SOF Error -> sending NACK";
        DevIo_SimpleWrite($hash, "15", 1);         # Send NACK
      }
      $data="";
      last;
    }

    my $len = substr($data, 2, 2);
    my $l = hex($len)*2;
    last if(!$l || length($data) < $l+4);       # Message not yet complete

    $msg = substr($data, 4, $l-2);
    my $rcs  = substr($data, $l+2, 2);          # Received Checksum
    $data = substr($data, $l+4);

    my $ccs = zwlib_checkSum_8("$len$msg");    # Computed Checksum
    if($rcs ne $ccs) {
      Log3 $name, 1,
           "$name: wrong checksum: received $rcs, computed $ccs for $len$msg";
      if(++$hash->{nrNAck} < 5) {
        Log3 $name, 5, "ZWDongle_Read wrong checksum -> sending NACK";
        DevIo_SimpleWrite($hash, "15", 1);
      }
      $msg = undef;
      $data="";
      next;
    }
    $hash->{nrNAck} = 0;
    Log3 $name, 4, "ZWDongle_Read $name: sending ACK, processing $msg";
    DevIo_SimpleWrite($hash, "06", 1);          # Send ACK
    ZWDongle_shiftSendStack($hash, 1, 5, "device ack reveived")
        if($msg =~ m/^0013/);
    
    last if(defined($local) && (!defined($regexp) || ($msg =~ m/$regexp/)));
    $hash->{PARTIAL} = $data;	 # Recursive call by ZWave get, Forum #37418
    ZWDongle_Parse($hash, $name, $msg) if($init_done);

    $data = $hash->{PARTIAL};
    $msg = undef;
  }

  $hash->{PARTIAL} = $data;
  
  # trigger sending of next message
  ZWDongle_ProcessSendStack($hash) if(length($data) == 0);
  
  return $msg if(defined($local));
  return undef;
}

#####################################
# This is a direct read for commands like get
sub
ZWDongle_ReadAnswer($$$)
{
  my ($hash, $arg, $regexp) = @_;
  Log3 $hash, 4, "ZWDongle_ReadAnswer arg:$arg regexp:".($regexp ? $regexp:"");
  return ("No FD (dummy device?)", undef)
        if(!$hash || ($^O !~ /Win/ && !defined($hash->{FD})));
  my $to = ($hash->{RA_Timeout} ? $hash->{RA_Timeout} : 3);

  for(;;) {

    my $buf;
    if($^O =~ m/Win/ && $hash->{USBDev}) {
      $hash->{USBDev}->read_const_time($to*1000); # set timeout (ms)
      # Read anstatt input sonst funzt read_const_time nicht.
      $buf = $hash->{USBDev}->read(999);
      return ("Timeout reading answer for get $arg", undef)
        if(length($buf) == 0);

    } else {
      if(!$hash->{FD}) {
        Log3 $hash, 1, "ZWDongle_ReadAnswer: device lost";
        return ("Device lost when reading answer for get $arg", undef);
      }

      my $rin = '';
      vec($rin, $hash->{FD}, 1) = 1;
      my $nfound = select($rin, undef, undef, $to);
      if($nfound < 0) {
        my $err = $!;
        Log3 $hash, 5, "ZWDongle_ReadAnswer: nfound < 0 / err:$err";
        next if ($err == EAGAIN() || $err == EINTR() || $err == 0);
        DevIo_Disconnected($hash);
        return("ZWDongle_ReadAnswer $arg: $err", undef);
      }

      if($nfound == 0){
        Log3 $hash, 5, "ZWDongle_ReadAnswer: select timeout";
        return ("Timeout reading answer for get $arg", undef);
      }

      $buf = DevIo_SimpleRead($hash);
      if(!defined($buf)){
        Log3 $hash, 1,"ZWDongle_ReadAnswer: no data read";
        return ("No data", undef);
      }
    }

    my $ret = ZWDongle_Read($hash, $buf, $regexp);
    if(defined($ret)){
      Log3 $hash, 4, "ZWDongle_ReadAnswer for $arg: $ret";
      return (undef, $ret);
    }
  }
}

sub
ZWDongle_Parse($$$)
{
  my ($hash, $name, $rmsg) = @_;

  if(!defined($hash->{STATE}) || 
     ReadingsVal($name, "state", "") ne "Initialized"){
    Log3 $hash, 4,"ZWDongle_Parse $rmsg: dongle not yet initialized";
    return;
  }

  $hash->{"${name}_MSGCNT"}++;
  $hash->{"${name}_TIME"} = TimeNow();
  $hash->{RAWMSG} = $rmsg;

  my %addvals = (RAWMSG => $rmsg);

  Dispatch($hash, $rmsg, \%addvals);
}

#####################################
sub
ZWDongle_Attr($$$$)
{
  my ($cmd, $name, $attr, $value) = @_;
  my $hash = $defs{$name};
  
  if($attr eq "disable") {
    if($cmd eq "set" && ($value || !defined($value))) {
      DevIo_CloseDev($hash) if(!AttrVal($name,"dummy",undef));
      readingsSingleUpdate($hash, "state", "disabled", 1);

    } else {
      if(AttrVal($name,"dummy",undef)) {
        readingsSingleUpdate($hash, "state", "dummy", 1);
        return;
      }
      DevIo_OpenDev($hash, 0, "ZWDongle_DoInit");

    }

  } elsif($attr eq "homeId") {
    $hash->{homeId} = $value;

  } elsif($attr eq "networkKey" && $cmd eq "set") {
    if(!$value || $value !~ m/^[0-9A-F]{32}$/i) {
      return "attr $name networkKey: not a hex string with a length of 32";
    }
    return;
  }

  return undef;  
  
}

#####################################
sub
ZWDongle_Ready($)
{
  my ($hash) = @_;

  return undef if (IsDisabled($hash->{NAME}));

  return DevIo_OpenDev($hash, 1, "ZWDongle_DoInit")
            if(ReadingsVal($hash->{NAME}, "state","") eq "disconnected");

  # This is relevant for windows/USB only
  my $po = $hash->{USBDev};
  if($po) {
    my ($BlockingFlags, $InBytes, $OutBytes, $ErrorFlags) = $po->status;
    if(!defined($InBytes)) {
      DevIo_Disconnected($hash);
      return 0;
    }
    return ($InBytes>0);
  }
  return 0;
}


1;

=pod
=begin html

<a name="ZWDongle"></a>
<h3>ZWDongle</h3>
<ul>
  This module serves a ZWave dongle, which is attached via USB or TCP/IP, and
  enables the use of ZWave devices (see also the <a href="#ZWave">ZWave</a>
  module). It was tested wit a Goodway WD6001, but since the protocol is
  standardized, it should work with other devices too. A notable exception is
  the USB device from Merten.
  <br><br>
  <a name="ZWDongledefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ZWDongle &lt;device&gt;</code>
  <br>
  <br>
  Upon initial connection the module will get the homeId of the attached
  device. Since the DevIo module is used to open the device, you can also use
  devices connected via  TCP/IP. See <a href="#CULdefine">this</a> paragraph on
  device naming details.
  <br>
  Example:
  <ul>
    <code>define zwdongle_1 ZWDongle /dev/cu.PL2303-000014FA@115200</code><br>
  </ul>
  </ul>
  <br>

  <a name="ZWDongleset"></a>
  <b>Set</b>
  <ul>

  <li>addNode [on|onNw|onSec|onNwSec|off]<br>
    Activate (or deactivate) inclusion mode. The controller (i.e. the dongle)
    will accept inclusion (i.e. pairing/learning) requests only while in this
    mode. After activating inclusion mode usually you have to press a switch
    three times within 1.5 seconds on the node to be included into the network
    of the controller. If autocreate is active, a fhem device will be created
    after inclusion. "on" activates standard inclusion. "onNw" activates network
    wide inclusion (only SDK 4.5-4.9, SDK 6.x and above).<br>
    If onSec/onNwSec is specified, the ZWDongle networkKey ist set, and the
    device supports the SECURITY class, then a secure inclusion is attempted.
    </li>

  <li>removeNode [onNw|on|off]<br>
    Activate (or deactivate) exclusion mode. "on" activates standard exclusion. 
    "onNw" activates network wide exclusion (only SDK 4.5-4.9, SDK 6.x and
    above).  Note: the corresponding fhem device have to be deleted
    manually.</li>

  <li>createNode id<br>
    Request the class information for the specified node, and create a fhem
    device upon reception of the answer. Used for previously included nodes,
    see the nodeList get command below.</li>

  <li>removeFailedNode<br>
    Remove a non-responding node -that must be on the failed Node list- from 
    the routing table in controller. Instead,always use removeNode if possible.
    Note: the corresponding fhem device have to be deleted manually.</li>

  <li>replaceFailedNode<br>
    Replace a non-responding node with a new one. The non-responding node
    must be on the failed Node list.</li>

  <li>reopen<br>
    First close and then open the device. Used for debugging purposes.
    </li>

  </ul>
  <br>

  <a name="ZWDongleget"></a>
  <b>Get</b>
  <ul>
  <li>nodeList<br>
    return the list of included nodenames or UNKNOWN_id, if there is no
    corresponding device in FHEM. Can be used to recreate fhem-nodes with the
    createNode command.</li>

  <li>homeId<br>
    return the six hex-digit homeId of the controller.</li>

  <li>isFailedNode<br>
    return if a node is stored in the failed node List.</li>

  <li>caps, ctrlCaps, version<br>
    return different controller specific information. Needed by developers
    only.  </li>

  <li>neighborList [onlyRep] nodeId<br>
    return data for the decimal nodeId.<br>
    With onlyRep the result will include only nodes with repeater
    functionality.
    </li>

  <li>nodeInfo<br>
    return node specific information. Needed by developers only.</li>

  <li>random N<br>
    request N random bytes from the controller.
    </li>

  <li>raw<br>
    Send raw data to the controller. Developer only.</li>
  </ul>
  <br>

  <a name="ZWDongleattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#dummy">dummy</a></li>
    <li><a href="#do_not_notify">do_not_notify</a></li>
    <li><a href="#model">model</a></li>
    <li><a href="#disable">disable</a></li>
    <li><a name="#homeId">homeId</a><br>
      Stores the homeId of the dongle. Is a workaround for some buggy dongles,
      wich sometimes report a wrong/nonexisten homeId (Forum #35126)</li>
    <li><a name="#networkKey">networkKey</a><br>
      Needed for secure inclusion, hex string with length of 32
      </li>
  </ul>
  <br>

  <a name="ZWDongleevents"></a>
  <b>Generated events:</b>
  <ul>
  <li>ZW_ADD_NODE_TO_NETWORK [learnReady|nodeFound|controller|done|failed]
    </li>
  <li>ZW_REMOVE_FAILED_NODE_ID 
           [failedNodeRemoveStarted|notPrimaryController|noCallbackFunction|
            failedNodeNotFound|failedNodeRemoveProcessBusy|
            failedNodeRemoveFail|nodeOk|nodeRemoved|nodeNotRemoved]
    </li>
  <li>ZW_REMOVE_NODE_FROM_NETWORK 
                        [learnReady|nodeFound|slave|controller|done|failed]
    </li>
  <li>ZW_REPLACE_FAILED_NODE 
           [failedNodeRemoveStarted|notPrimaryController|noCallbackFunction|
            failedNodeNotFound|failedNodeRemoveProcessBusy|
            failedNodeRemoveFail|nodeOk|failedNodeReplace|
            failedNodeReplaceDone|failedNodeRemoveFailed]
    </li>
  <li>UNDEFINED ZWave_${type6}_$id ZWave $homeId $id $classes"
    </li>
  <li>ZW_REQUEST_NODE_NEIGHBOR_UPDATE [started|done|failed]
    </li>
  </ul>

</ul>


=end html
=cut
