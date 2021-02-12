package cardsim;
#------------------------------------------------------------------#
#       cardsim: Simulate the response of a QN DAQ card so that    #
#                software can be realistically tested without      #
#                requiring a card attached to the system           #
#------------------------------------------------------------------#
use strict;
use warnings;
use Time::HiRes qw(usleep);
use POSIX;

my $CRLF = "\012\015";
my $CR   = "\012";
my $LF   = "\015";

#------------------------------------------------------------------#
#   Massive hash available everywhere in this package which        #
#   contains a copy of the way the card on my desk responds to     #
#   various commands. Commands which query (e.g. DC) just return   #
#   that element of the hash. Commands which update something      #
#   (e.g. WC ...) change the appropriate value in the hash so      #
#   that subsequent queries return the new value. The new values   #
#   persist until the destroy function is called.                  #
#------------------------------------------------------------------#
my %cardResponse = (
    'SN' => "SN\nSerial#=6999",
    'TL' => "TL\nTL L0=425 L1=300 L2=300 L3=300",
    'HE' => "HE                                                              
Quarknet Scintillator Card,  Qnet2.5  Vers 1.06  Compiled Oct 10 2009  HE=Help
Serial#=6150     uC_Volts=3.35      GPS_TempC=0.0     mBar=1011.3

CE     - TMC Counter Enable.
CD     - TMC Counter Disable.
DC     - Display Control Registers, (C0-C3).
WC a d - Write   Control Registers, addr(0-6) data byte(H).
DT     - Display TMC Reg, 0-3, (1=PipeLineDelayRd, 2=PipeLineDelayWr).
WT a d - Write   TMC Reg, addr(1,2) data byte(H), if a=4 write delay word.
DG     - Display GPS Info, Date, Time, Position and Status.
DS     - Display Scalar, channel(S0-S3), trigger(S4), time(S5).
RE     - Reset complete board to power up defaults.
RB     - Reset only the TMC and Counters.
SB p d - Set Baud,password, 1=19K, 2=38K, 3=57K ,4=115K, 5=230K, 6=460K, 7=920K
SA n   - Save setup, 0=(TMC disable), 1=(TMC enable), 2=(Restore Defaults).
TH     - Thermometer data display (@ GPS), -40 to 99 degrees C.
TL c d - Threshold Level, signal ch(0-3)(4=setAll), data(0-4095mV), TL=read.
View   - View setup registers(cmd=V1), Voltages(V2), GPS LOCK(V3).
HELP   - HE,H1=Page1, H2=Page2, HB=Barometer, HS=Status, HT=Trigger.",

'DC' => "DC\nDC C0=2D C1=70 C2=0A C3=00",
'V1' => "V1
 Run Mode       : Off         CE (cnt enable), CD (cnt disable)
 Ch(s) Enabled  : 3,2,0     Cmd DC  Reg C0 using (bits 3-0)
 Veto Enable    : Off
 Veto Select    : Ch0         Cmd DC  Reg C0 using (bits 7,6)
 Coincidence 1-4: 3-Fold      Cmd DC  Reg C0 using (bits 5,4)
 Pipe Line Delay:    40 nS    Cmd DT  Reg T1=rDelay  Reg T2=wDelay  10nS/cnt
 Gate Width     :   100 nS    Cmd DC  Reg C2=LowByte Reg C3=HighByte 10nS/cnt
 Ch0 Threshold  : 0.425 vlts
 Ch1 Threshold  : 1.234 vlts
 Ch2 Threshold  : 0.300 vlts
 Ch3 Threshold  : 0.300 vlts
 Test Pulser Vlt: 3.000 vlts
 Test Pulse Ena : Off

 Example line for 1 of 4 channels. (Line Drawing, Not to Scale)
 Input Pulse edges (begin/end) set rising/falling tags bits.
 ____~~~~~~_________________________________ Input Pulse, Gate cycle begins
 __________________~________________________ Delayed Rise Edge 'RE' Tag Bit
 ________________________~__________________ Delayed Fall Edge 'FE' Tag Bit
     _____________                           Tag Bits delayed by PipeLnDly
 ___|             |_________________________ PipeLineDelay :   40nS
                   _____________________
 _________________|                     |___ Capture Window:   60nS
     ___________________________________
 ___|                                   |___ Gate Width    :  100nS

 If 'RE','FE' are outside Capture Window, data tag bit(s) will be missing.
 CaptureWindow = GateWidth - PipeLineDelay
 The default Pipe Line Delay is 40nS, default Gate Width is 100nS.
 Setup CMD sequence for Pipeline Delay.  CD,  WT 1 0, WT 2 nn (10nS/cnt)
 Setup CMD sequence for Gate Width.  CD, WC 2 nn(10nS/cnt), WC 3 nn (2.56uS/cnt)",

'V2' => "V2
Barometer Pressure Sensor
  Calibration Voltage  = 1495 mVolts   Use Cmd 'BA' to calibrate.
  Sensor Output Voltage= 1467 mVolts   (2.93mV *  501 Cnts)
  Pressure mBar        = 1011.1        (1467.9 - 1500)/ 15 + 1013.25
  Pressure inch        = 30.25         (mBar / 33.42)

Timer Capture/Compare Channel
  TempC  = 0.0     Error?  Check sensor cable connection.
  TempF  = 32.0    (TempC * 1.8) + 32

Analog to Digital Converter Channels(ADC)
  Vcc 1.8V = 1.81 vlts     (2.93mV *  619 Cnts)
  Vcc 1.2V = 1.20 vlts     (2.93mV *  411 Cnts)
  Pos 2.5V = 2.48 vlts     (2.93mV *  848 Cnts)
  Neg 5.0V = 5.03 vlts     (7.38mV *  682 Cnts)
  Vcc 3.3V = 3.35 vlts     (3.33mV * 1007 Cnts)
  Pos 5.0V = 5.11 vlts     (7.38mV *  693 Cnts)
  5V Test    Max=5.12v    Min=5.11v    Noise=0.007v",

'V3' => "V3
 10 Second Accumulation of 1PPS Latched 25MHz Counter. (20 line buffer)
  Buffer     Now (hex)     Prev-Now (dec) (25e6*10)
     1         ------          ------    Updating buffer  1
     2              0               0
     3              0               0
     4              0               0
     5              0               0
     6              0               0
     7              0               0
     8              0               0
     9              0               0
    10              0               0
    11              0               0
    12              0               0
    13              0               0
    14              0               0
    15              0               0
    16              0               0
    17              0               0
    18              0               0
    19              0               0
    20              0               0",

'DG' => "DG
 Date+Time: 18/02/11 13:58:39.028
 Status:    A (valid)
 PosFix#:   1
 Latitude:   41:41.302721 N
 Longitude: 086:14.182195 W
 Altitude:  220.686m
 Sats used: 9
 PPS delay: +0000 msec         (CE=1 updates PPS,FPGA data)
 FPGA time: 00000000
 FPGA freq:        0 Hz        (Cmd V3, freq history)
 ChkSumErr: 0",

'DT' => "DT\nDT T0=00 T1=77 T2=7B T3=00",

'DS' => "DS\nDS S0=15EC49E2 S1=1FDACAFC S2=00000000 S3=395EA9BE S4=007B4489 S5=00000000",

'RE' => "RE

Qnet Hardware Version 2.5
IAR Compiler Vers 4.41                  
FPGA-Load: 63653 bytes loaded, CheckSum=0xC0DB
FPGA-Load: ConfigDone Ok!

Quarknet Scintillator Card,  Qnet2.5  Vers 1.06  Compiled Oct 10 2007  HE=Help
Serial#=6150     uC_Volts=3.35      GPS_TempC=24.4     mBar=1017.8
Ready, Counters Disabled.",

'TH' => "TH\nTH TH=24.5",

'HB' => "HB
 BA      - Display barometer data as raw counts(BCD) and mBar.
 BA bbbb - Calibrate by setting trim DAC Ch voltage(0-4095mV).",

'HS' => "HS
Trigger IRQ Status Byte, bit assignments (see \"HT\" for location on data line)
 0x1 = Unused
 0x2 = Trigger FIFO full     (1Hz uC STAT LED flash increases if FIFO_full)
 0x4 = Unused
 0x8 = Current or last 1PPS tick not within 25MHz +/-50 nSec

Status Line Format for BCD1-BCD19,  see \"ST\" command.
 BCD1 ->   mBar
 BCD2 ->   GPS_DegC      (format nn.n)
 BCD3 ->   1PPS Delay    (mSec, hardware pulse to ASCII NMEA data)
 BCD4 ->   CPU_Vcc(3.3v) (mVolts)
 BCD5 ->   GPS_UTC
 BCD6 ->   GPS_DATE
 BCD7 ->   GPS_VALID     (A=Valid)
 BCD8 ->   GPS_SAT Count
 BCD9 ->   1PPS Time
 BCD10->   Code Version  (format n.nn)
 BCD11->   Serial #
 BCD12-15> TMCregs  3-0  (4 tmc regs displayed as a 32 Bit#)
 BCD16-19> Cntlregs 3-0  (4 cntrl regs displayed as a 32 Bit#)

ST 1008 +273 +086 3349 180022 021007 A  05 C5ED5FF1 106 6148 00171300 000A710F
   mBar   | 1ppsDly |  GpsUTC   | GpsVld | 1ppsTime  | SerNum   |     Cntlregs
       GpsDegC   CPU_Vcc     GpsDate   GpsSat#    CodeVer    TMCregs

DS 000006B4 00001413 00000D62 000006B1 00001414
   Ch0Cnts  Ch1Cnts  Ch2Cnts  Ch3Cnts  TrigCnt",

'HT' => "HT
 Timer Counter Bits 31..0  ( 8 bytes ascii)
 RE0 TAG  RE0 DATA         ( 2 bytes ascii) -- 
 FE0 TAG  FE0 DATA         ( 2 bytes ascii)   | 
 RE1 TAG  RE1 DATA         ( 2 bytes ascii)   | \"0x80=Event_Demarcation_Bit\"
 FE1 TAG  FE1 DATA         ( 2 bytes ascii)   | \"0x20=Edge_Tag_Bit\"
 RE2 TAG  RE2 DATA         ( 2 bytes ascii)   | \"0x1F=Data,(5 bits)\"
 FE2 TAG  FE2 DATA         ( 2 bytes ascii)   | 
 RE3 TAG  RE3 DATA         ( 2 bytes ascii)   |
 FE3 TAG  FE3 DATA         ( 2 bytes ascii) -- 
 1PPS TIME Bits 31..0      ( 8 bytes ascii)
 GPS RMC UTC  hhmmss.sss   (10 bytes ascii)     Status Flag bits
 GPS RMC DATE ddmmyy       ( 6 bytes ascii)      0x1 = Unused
 GPS RMC STATUS A=valid    ( 1 byte  ascii)      0x2 = Trigger FIFO full
 GPS GGA SATELLITES USED   ( 2 bytes ascii)      0x4 = Unused
 TRIG IRQ STATUS FLAGS     ( 1 byte  ascii)      0x8 = 1PPS > +/-50nSec
 GPS 1PPS to DATA DELAY mS ( 5 bytes ascii)
                                                            GPS Status
    Example data line with GPS receiving 5 satellites.      |
DE799F14 BB 00 00 00 00 00 00 00 DE1C993A 132532.010 111007 A 05 0 +0060
DE799F15 00 00 00 00 21 00 00 00 DE1C993A 132532.010 111007 A 05 0 +0060
DE799F15 00 35 00 00 00 00 00 00 DE1C993A 132532.010 111007 A 05 0 +0060
DE799F15 00 00 00 00 00 3C 00 00 DE1C993A 132532.010 111007 A 05 0 +0060
|______|| ch0 | ch1 | ch2 | ch3 ||______| |________| |____|   |  |  |_1ppsDelay
  Timer  RE-FE RE-FE RE-FE RE-FE 1pps Hex  GPS Time   Date    |  |_Status Flag
40nS/cnt    1.25nS/cnt(5 bits)                        DMY     |_Satellites Used

    View Mode 1 example
ED608136 3100     0  3700     0  3976416186 132542.010 111007 A 05 0 +0060
ED608137   2C     0     0     0  3976416186 132542.010 111007 A 05 0 +0060
ED608137    0     0    32     0  3976416186 132542.010 111007 A 05 0 +0060
  Timer   ch0   ch1   ch2   ch3  1pps Dec",

'H2' => "H2
Barometer      Qnet Help Page 2
 BA      - Display Barometer trim setting in mVolts and pressure as mBar.
 BA d    - Calibrate Barometer by adj. trim DAC ch in mVlts (0-4095mV).
Flash
 FL p    - Load Flash with Altera binary file(*.rbf), p=password.
 FR      - Read FPGA setup flash, display sumcheck.
 FMR p   - Read page 0-3FF(h), (264 bytes/page)
           Page 100h= start fpga *.rbf file, page 0=saved setup.
GPS
 NA 0    - Append NMEA GPS data Off,(include 1pps data).
 NA 1    - Append NMEA GPS data On, (Adds GPS to output).
 NA 2    - Append NMEA GPS data Off,(no 1pps data).
 NM 0    - NMEA GPS display, Off, (default), GPS port speed 38400, locked.
 NM 1    - NMEA GPS display (RMC + GGA + GSV) data.
 NM 2    - NMEA GPS display (ALL) data, use with GPS display applications.
Test Pulser
 TE m    - Enable run mode,  0=Off, 1=One cycle, 2=Continuous.
 TD m    - Load sample trigger data list, 0=Reset, 1=Singles, 2=Majority.
 TV m    - Voltage level at pulse DAC, 0-4095mV, TV=read.
Serial #
 SN p n  - Store serial # to flash, p=password, n=(0-65535 BCD).
 SN      - Display serial number (BCD).
Status
 ST      - Send status line now.  This reset the minute timer.
 ST 0    - Status line, disabled.
 ST 1 m  - Send status line every (m) minutes.(m=1-30, def=5).
 ST 2 m  - Include scalar data line, chs S0-S4 after each status line.
 ST 3 m  - Include scalar data line, plus reset counters on each timeout.
TI n     - Timer (day hr:min:sec.msec), TI=display time, (TI n=0 clear).
U1 n     - Display Uart error counter, (U1 n=0 to zero counters).
VM 1     - View mode, 0x80=Event_Demarcation_Bit outputs a blank line.
         - View mode returns to normal after 'CD','CE','ST' or 'RE'.",
'BA' =>"BA
BA 1495
 Adjust this count 1495 to calibrate sensor in mBar.
 mBar now reads  = 1017.8",

'H3' => "H3
              Qnet Rev2.5 (Help, Direct FPGA Cmds)
RD  a32     - Read  address32, returns d32.
RDM a32 nn  - Read  address32 nn(hex) times, returns multiple d32.
WR  a32 d32 - Write address32 with data32.
UL password - Upload new binary data file to NavSync GPS module.
            - Uploads use USB baud of 38400 or less, GPS baud is fixed at 38400
UM 'msg'    - Upload single ascii NMEA message to NavSync module.
            - Don't include \$ or checksum with message.
            - Example.. Query freq output= PRTHQ,FRQD
            - To view NavSync response 'NM 2' must be active.",

'ST' => "ST 1011 +278 +000 3353 161201 280411 A 08 00000000 106 6199 00494500 000A702B
DS 00000000 00000000 00000000 00000000 00000000 "
    );

#------------------------------------------------------------------#
#               The actual class instantiator                      #
#------------------------------------------------------------------#
sub new {

    my ($class) = @_;

    my $self = {
	_socket   => undef
    };

    bless $self, $class;
    return $self;
}

#----------------------------------------#
# Utility functions that do nothing but  #
# hold place for mimicing Device::Serial #
# in case there's no actual hardware     #
#----------------------------------------#
sub baudrate {
    my ( $self, $rate ) = @_;
    return $rate;
}
sub parity {
    my ($self,$parity) = @_;
    return $parity;
}
sub databits {
    my ($self,$bits) = @_;
    return $bits;
}
sub stopbits {
    my ( $self, $bits ) = @_;
    return $bits;
}
sub handshake {
    my ( $self, $shake ) = @_;
    return $shake;
}
sub read_const_time {
    my ( $self, $time ) = @_;
    return $time;
}
sub read_char_time {
    my ( $self, $time ) = @_;
    return $time;
}
sub write_settings {
    my ( $self ) = @_;
    return 1;
}
#------------------------------------------------------------------#
#                        The class destructor                      #
#------------------------------------------------------------------#
sub close() {
    my ($self) = @_;
    undef %cardResponse;

    if ( $main::verbose ) {
	print "Destroying simulator\n";
    }

    if ( $self->{_zipFile} ) {
	$self->{_zipFile}->close();
    }

    undef $self;
    return undef;
}

sub openZipFile {
    my ( $path ) = @_;
    use IO::Uncompress::Unzip qw(unzip $UnzipError);

    my $now = localtime();
    my $z = new IO::Uncompress::Unzip $path
	or warn "[$now] unzip failed: $UnzipError\n";
    return $z;
}

#------------------------------------------------------------------#
#           Full on card simulation.... just for fun :P            #
#   For queries... grab the proper response from the global hash   #
#   For settings command, grab the response from the hash & do a   #
#   RegExp substitution into the proper place so that subsequent   #
#   queries will return the new value as though you actually up-   #
#   dated a card. Not everything is simulated, just enough to      #
#   make it seem worthwhile as a test bed. If the query can't be   #
#   found in the hash, return " Cmd??" just like the card does     #
#------------------------------------------------------------------#
sub write {
    my ($self, $command) = @_;

    # Massage the command so we're sure it'll work
    $command =~ s/\r|\n//g;
    $command = uc($command);

    # Store the command as if it were written
    $self->{_command} = $command;

    # And return the "write" result
    return eval(length($command)+1);
}

sub read {
    my ( $self ) = @_;
    my $command = $self->{_command};
    my $result = '\0';

    # If there's a command in the queue... Use it to
    # grab the proper response from the response hash
    if ( $command ) {

	if ( $command =~ /CE/ ) {
	    # Find our zip file with the data...
	    my $simFile =  "lib/QN/crd-100908112157.zip";

	    if ( -r $simFile ) {
	    } elsif ( -r $ENV{'OURHOME'}."/$simFile" ) {
		$simFile = $ENV{'OURHOME'} . "/$simFile";

	    } elsif ( -r $ENV{'SYSHOME'}."/$simFile" ) {
		$simFile = $ENV{'SYSHOME'} . "/" . $simFile;
	    }

	    my $zipFile = openZipFile($simFile) or 
		warn "Unable to open $simFile: $!";
	    if ( $zipFile ) {

		$self->{_zipFile} = $zipFile;

		my $counter = 0;
		my @lines = ();
		while ($counter++ < 50) {
		    my $line = $self->{_zipFile}->getline();
		    $line =~ s/\r|\n//g;
		    push(@lines, $line);
		}
		$result = "";
		$self->{_lines} = \@lines;
	    } else {
		warn "Can't simulate card\n";
	    }
	} elsif ( $command =~ /CD/ ) {
	    
	    if ( $self->{_zipFile} ) {
		$self->{_zipFile}->close();
		$self->{_zipFile} = undef;
	    }

	    $result = "CD";
	    my @lines = ("CD");
	    $self->{_lines} = \@lines;

	} else {

	    # Get the response
	    $result = $self->simulateCard($command);

	    # Store the result by line so we can respond 
	    # to multiple reads a line at a time
	    my @lines = split(/\n/, $result);
	    $self->{_lines} = \@lines;

	}

	# Flush the command.... it's already dealt with
	$self->{_command} = undef;

	# Initialize a counter so we can remember where we were
	$self->{_counter} = 0;
    }

    # Get a reference to the response array
    my $lines = $self->{_lines};

    # Recall where we were
    my $counter = $self->{_counter};
    my $length = 0;

    # Are we done? Return a null
    if ( !$lines || $counter >= scalar(@$lines) ) {

	if ( $self->{_zipFile} ) {
	    my $count = 0;
	    my @data  = ();
	    while ( $count++ < 50 ) {
		my $line = $self->{_zipFile}->getline();
		$line =~ s/\r|\n//g;
		push( @data, $line );
		$self->{_lines} = ();
		$self->{_lines} = \@data;
		$lines = $self->{_lines};

		$counter = 0;
		$result = @$lines[$counter++];
		$result .= "\n";
		$length = length($result);
	    }
	} else {
	    $length = 0;
	    $self->{_lines} = undef;
	    $self->{_counter} = 0;
	    $result = undef;
	}
    } else {
	# Get the current response
	$result = @$lines[$counter++];
	$result .= "\n" if $result;
	$length = (defined($result)) ? length($result) : 0;
    }

    # Store the current counter
    $self->{_counter} = $counter;

    if ( $self->{_zipFile} ) {
	my $freq = 1.0/5.67;
	my $msecs = rand(1000000 * $freq);
	Time::HiRes::usleep($msecs);
    }

    # And return the result SerialPort style
    return $length,$result;
}

sub simulateCard {
    my ($self,$query) = @_;

    if ( !$query ) {
	return " Cmd??$CRLF";
    }

    $query = uc($query);

    if ( $query =~ /^TL (\d+) (\d+)$/ ) {
	# The user is trying to change something or other
	# grab hold of the what & the wherefore
	my $chan = int($1);
	my $threshold = $2;

	$cardResponse{"TL"} =~ /.*L$chan=(\d+).*/;
	my $level = $1;

	$cardResponse{'TL'} =~ s/L$chan=$level/L$chan=$threshold/;

	return "TL$CRLF";
    
    # Simulate setting the status line
    } elsif ( $query =~ /ST .*/ ) {
	return "$query\nST Enabled, with scalar data.";

    # Simulate a write control register command
    } elsif ( $query =~ /WC (\d+) (.*)/ ) {
	my $reg = int($1);
	my $value = $2;

	my $registers = $cardResponse{'DC'};
	$registers =~ /.*C$reg=(..).*/;

	my $oldval = $1;

	$registers =~ s/C$reg=$oldval/C$reg=$value/;
	$cardResponse{'DC'} = $registers;

	return "WC 0$reg=$value$CRLF";

    } elsif ( $query =~ /WT/ ) {
	return "WT$CRLF";

    # No actual response... but flush the scalar buffers
    } elsif ( $query =~ /RB/ ) {
	$cardResponse{'DS'} = "DS\nDS S0=00000000 S1=00000000 S2=00000000 S3=00000000 S4=00000000 S5=00000000";
	return "RB$CRLF";

    } elsif ( $query =~ /DG/ ) {

	# Form up a date that looks like 18/02/11 13:58:39.028
	my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
	$mon++;
	$year += 1900;
	my $msec = int(rand(1000)) - 1;
	
	my $datetime = sprintf( "%02i/%02i/%02i %02i:%02i:%02i.%03i",
				$mday,$mon,$year,$hour,$min,$sec,$msec);

	$cardResponse{'DG'} =~ s/Date\+Time: .*/Date\+Time: $datetime/;

    # Pretend we just flush the buffers & reloaded the firmware
    # (firmware reload response is in the hash, so no return in
    # here, just let the response happen at the end of the function)
    } elsif ( $query =~ /RE/ ) {
	$cardResponse{'DS'} = "DS\nDS S0=00000000 S1=00000000 S2=00000000 S3=00000000 S4=00000000 S5=00000000";

    # Simulate an update to the barometric pressure sensor
    } elsif ( $query =~ /BA (\d+)/ ) {
	my $value = $1;

	$cardResponse{'BA'} =~ /BA (\d+)\n.*/;
	my $oldval = $1;

	$cardResponse{'BA'} =~ s/$oldval/$value/g;

	return "$CRLF";

    # First help page... same response as an HE.
    } elsif ( $query =~ /H1/ ) {
	$query = "HE";

    # Simulate a counter enable from previous data running
    } elsif ( $query =~ /CE/ ) {
	return "CE$CRLF";

    # Stop the CE simulator
    } elsif ( $query =~ /CD/ ) {
	return "CD$CRLF";
    }

    # Default response: Look up the proper response in
    # the cardResponse hash and send it back
    if ( defined($cardResponse{$query}) ) {
	return $cardResponse{$query}.$CRLF;

    # Not there? Return the stock card error response
    } else {
	return " Cmd??$CRLF";
    }
}

return 1;
