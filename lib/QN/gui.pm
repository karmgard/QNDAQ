package gui;

use strict;
use warnings;

use Tk;
use Tk::NoteBook;
use Tk::TextUndo;
use Tk::ProgressBar;
use Tk::ROText;

use Tk::SplashScreen;    # Non-standard -- had to be installed on Ubuntu
use Tk::MacProgressBar;

my @threshold = (-1, -1, -1, -1 );
my @oldThresh = (-1, -1, -1, -1 );
my @threshArray = ();

my $cLevel = 0;
my @activePaddle = (0,0,0,0);
my @cLevelBtns = ();
my @activeBtns = ();

my $main;
my $txt;
my $status;

my $but;
my $exitBtn;
my ($startButton, $stopButton);
my $dataStreamTxt;

my $splash;
my $MAC_PB;
my $label;

sub new {

    my ($class, $daqPtr) = @_;
    my $self = {
	_daq    => $daqPtr,
	_STATUS => 0,
	_UPDID  => 0
    };

    bless $self, $class;

    # Build the main window
    $self->buildMain();
    
    # Update the splash screen created in buildMain
    $MAC_PB->set(10);

    $label->configure( -text => 'Initializing DAQ Card...' );
    $label->update();

    $self->init();

    $splash->Destroy();                    # tear down Splashscreen
    $main->deiconify();                    # show main window

    $self->{_STATUS} = 1;

    # Push a card status reader into the background
    system("./card_read.pl&");

    # Wait half a moment and start updating the status line on the GUI
    $status->repeat(1000, sub { $self->{_UPDID} = $self->updateStat(); });

    return $self;
}

sub buildMain {
    my ( $self ) = @_;

    # Build the main window
    $main = MainWindow->new;
    $main->geometry('640x485');
    $main->protocol('WM_DELETE_WINDOW' => \&exitMain);
    $main->bind($main, "<Control-q>" => \&exitMain);

    $splash = $main->Splashscreen(-milliseconds => 3000, -bg => '#d3d3d3');
    $label = 
	$splash->Label(-text => 'Building Interface ...', -bg => '#ff00ff')->
	grid( -sticky => 'nsew' );
    $MAC_PB = $splash->MacProgressBar(-width => 400);
    $MAC_PB->grid( -sticky => 'nsew' );
    $splash->Label(-image => $main->Photo(-file => 'quarknet_header.gif'))->grid();

    $main->withdraw();
    $splash->Splash();                   # show Splashscreen

    $MAC_PB->set(1);

    my $btnFrame = 
	$main->Frame()->grid(-sticky => 'ew', -row => 0, -pady => 10);

# Put up the global buttons
    $but = 
	$btnFrame->Button(-text=>"Help", 
			  -command =>\&getHelp)->grid(-row => 0, -column => 0);
    $exitBtn = 
	$btnFrame->Button(-text=>"Exit", 
			  -command =>\&exitMain)->grid(-row => 0, -column => 2);
    $btnFrame->gridColumnconfigure(2, -weight => 1);

    # Update the splash screen
    $MAC_PB->set(2);

    my $tabs = $main->NoteBook()->grid(-sticky => 'nsew', -row => 1);
    my $trigTab = $tabs->add("trigger", -label => "Trigger");
    my $queTab  = $tabs->add("query",   -label => "Query");
    my $runTab  = $tabs->add("data",    -label => "Run");
    my $entTab  = $tabs->add("text",    -label => "Terminal");

    $status = $main->Label(-text => 'DAQ Status')->
	grid( -sticky => 'w', -row => 3, -pady => 1);

    # Update the splash screen
    $MAC_PB->set(3);

    my $trigFrame = 
	$trigTab->Frame()->grid( -sticky => 'nsew' );

    my $entFrame = 
	$entTab->Frame()->grid( -sticky => 'nsew' );

# Frame the columns for the triggering block
    my $threshFrame = $trigFrame->Frame( -padx => '1',
					 -relief=>'raised',
					 -border => 1 )->grid(-rowspan => 2, -column => 0, -row => 0);
    my $tLabel = $threshFrame->Label(-text=>"Thresholds")->grid();

    my $coinceFrame = $trigFrame->Frame( -padx => '1', 
					 -relief=>'raised',
					 -border => 1  )->grid(-column => 1, -row => 0);
    my $cLabel = $coinceFrame->Label(-text=>"Coincidence")->grid();

    my $paddleFrame = $trigFrame->Frame( -padx => '13',
					 -relief=>'raised',
					 -border => 1  )->grid(-column => 1, -row => 1);
    my $pLabel = $paddleFrame->Label(-text=>"Paddles", -borderwidth => 2)->grid();

    $trigFrame->gridColumnconfigure(2, -weight => 1);

    # Update the splash screen
    $MAC_PB->set(4);

    for ( my $i=0; $i<4; $i++ ) {
	$threshArray[$i] = 
	    $threshFrame->Scale( 
		-label => "Ch $i (mV)",
		-width => 10, -length => 256,
		-from => 0, -to => 4095, -bigincrement => 256,
		-showvalue => 1, -orient => 'horizontal', 
		-borderwidth => 1, -showvalue => 1,
		-variable => \$threshold[$i] 
	    )->grid();

	$cLevelBtns[$i] =
	    $coinceFrame->Radiobutton(
		-text => ($i+1 . "-fold"), -value => $i, -variable => \$cLevel,
		-command => sub {$self->setCoincidence($cLevel, @activePaddle);}, 
		-pady => 3
	    )->grid();

	$activeBtns[$i] = 
	    $paddleFrame->Checkbutton(
		-text => $i, -variable => \$activePaddle[$i],
		-command => sub {$self->setCoincidence($cLevel, @activePaddle);},
		-pady => 3
	    )->grid();
    }
    my $threshBtnFrame = $threshFrame->Frame()->grid();
    $threshold[4] = 
	$threshBtnFrame->Button(-text => 'Set', 
			     -command => sub {$self->setThreshold;} )->grid(-column => 1, -row => 0);

    $threshold[5] = 
	$threshBtnFrame->Button(-text => 'Reset', 
			     -command => sub {$self->resetThreshold;} )->grid(-column => 2, -row => 0);

    # Update the splash screen
    $MAC_PB->set(5);

#
#
# Set up a terminal emulator for direct access to the card
    $txt = $entFrame->Scrolled('TextUndo', -scrollbars => 'oe',
			       -foreground => 'red', 
			       -background => 'white')->grid();
# Automate the scrollbar
    $txt->Subwidget( 'yscrollbar' )->configure(
	-command => [ 'yview' => $txt ] );

    # Update the splash screen
    $MAC_PB->set(6);

# Allow the user to save the terminal output
    $main->bind($main, "<Control-s>" => \&onFileSave);
    $txt->bind("Tk::TextUndo", "<Control-s>" => \&onFileSave);
    $txt->bind("Tk::TextUndo", 
	       "<KeyRelease-Return>" => sub {$self->terminalCmd($txt->index('insert'));}
	);
    $txt->tagConfigure('output', -foreground => 'black');
    $txt->tagConfigure('input',  -foreground => 'red');

    # Update the splash screen
    $MAC_PB->set(7);


#
### Build the "Run" widgets
#
    my $runBtnFrame = $runTab->Frame()->grid(-sticky => 'ew', -row => 0);
    $startButton   = $runBtnFrame->Button(-text => 'Start',
	-command => sub{ $self->startData();} )->grid(-row => 0, -column => 1);
    $stopButton    = $runBtnFrame->Button(-text => 'Stop' , 
					  -state => 'disabled',
					  -command => sub {$self->stopData();} )->grid(-row => 0, -column => 2);

    my $dataFrame  = $runTab->Frame->grid(-sticky => 'nsew', -row => 1); 
    $dataStreamTxt = $dataFrame->ROText()->grid( -sticky => 'nsew' );

    # Update the splash screen
    $MAC_PB->set(8);

    return;
}

my $DAQFILE;
sub startData {
    my ($self) = @_;
    $startButton->configure( -state => 'disabled' );
    $stopButton->configure( -state => 'active' );

    $startButton->update();
    $stopButton->update();

    # Inhibit the trigger update status line for now
    # It'll be updated by the take_data routine
    $self->{_STATUS} = 0;
    $self->{_UPDID}->cancel();

    $self->{_daq}->take_data($dataStreamTxt, $status);

    return;
}

sub stopData {
    my ($self) = @_;
    $startButton->configure( -state => 'active' );
    $stopButton->configure( -state => 'disabled' );

    $startButton->update();
    $stopButton->update();

    $self->{_daq}->stop_data();

    # Resume the status line updates
    $self->{_STATUS} = 1;
    $status->repeat(1000, sub { $self->{_UPDID} = $self->updateStat(); });

    return;
}

use IO::Socket;
sub updateStat {
    my ($self) = @_;
    my $daq = $self->{_daq};
    my $stat = "";

    if ( !$daq || $self->{_STATUS} == 0 ) {
	return;
    }

    $main->update();

    my $sock = IO::Socket::INET->new(
	PeerAddr => 'localhost',
	Proto    => 'tcp',
	PeerPort => 8979,
	Block    => 0
	);
    warn "$!\n" unless defined $sock;

    $sock->autoflush(1);
    print $sock "ready\n";

    $main->update();

    $stat = <$sock>;
    $sock->close();

    $main->update();

    if ( $stat =~ /GPS/ ) {
	$status->configure(-text => $stat);
	$main->update();
	$status->update();
    }

    return;
}

sub init {
    my ($self) = @_;
    my $daq = $self->{_daq};

    # Update the splash screen
    $MAC_PB->set(25);
    $label->configure( -text => 'Identifying card...');
    $label->update();

    # Grab the serial number & display it in the title
    my $serial = $daq->send("SN");
    if ( defined $serial ) {
	$serial =~ /Serial#=(\d+)/;

	if ( defined $1 ) {
	    $serial = $1;
	} else {
	    undef $serial;
	}
    }
    if ( defined $serial ) {
	$main->title('QuarkNet DAQ Card #' . $serial);
    } else {
	$main->title('QuarkNet DAQ Card');
    }

    # Update the splash screen
    $MAC_PB->set(50);
    $label->configure( -text => 'Getting thresholds...');
    $label->update();

    # Get the current thresholds and set the sliders accordingly
    $self->resetThreshold();

    # Update the splash screen
    $MAC_PB->set(75);
    $label->configure( -text => 'Getting trigger setup...');
    $label->update();

    # Get the current trigger setup from register 0
    my $trigs = $daq->send("DC");
    if ( defined $trigs ) {
	$trigs =~ /DC C0=(\d)(\S)*/;
	$cLevel = ( defined $1 ) ? $1 : 0;

	my $pActive = ( defined $2 ) ? hex($2) : 0;
	for ( my $i=0; $i<4; $i++ ) {
	    $activePaddle[$i] = ((1<<$i) & $pActive) ? 1 : 0;
	}
    }

    # Done initiallizing... update the splash screen & return
    $MAC_PB->set(100);
    $label->configure( -text => 'Done');
    $label->update();

    return;
}

# Tk main loop... runs until exitMain is called
sub runMainLoop {
    my ($self) = @_;

    MainLoop;
    return;
}

sub terminalCmd {
    my ( $self, $lineNum ) = @_;
    my $cmd;
    my $daq = $self->{_daq};

    if ( defined $lineNum ) {
	($lineNum) = split(/\./, $lineNum);
	$lineNum--;
	$cmd = $txt->get("$lineNum.0", "$lineNum.end");
	chomp($cmd);
    }

    updateTerminal($daq->send($cmd), 'output');
    return;
}

# The TextUndo widget has a file save dialog box method built-in!
sub onFileSave {
    $txt->FileSaveAsPopup();
    return;
}

sub setCoincidence {
    my ($self, $coincidence, @paddles) = @_;
    my $daq = $self->{_daq};

    for ( my $i=0; $i<4; $i++ ) {
	$activeBtns[$i]->update();
	$cLevelBtns[$i]->update();
    }

    my @hexVals = ('A', 'B', 'C', 'D', 'E', 'F');
    my $value = $paddles[0] + 2*$paddles[1] + 4*$paddles[2] + 8*$paddles[3];

    $value = ( $value > 9 ) ? $hexVals[$value-10] : $value;
    my $cmd = 'WC 00 ' . $coincidence . $value;
    &updateTerminal( $cmd . "\n", 'input' );
    &updateTerminal( $daq->send($cmd) );
    return;
}

sub getHelp {
    my ($self) = @_;
    my $daq = $self->{_daq};

    $but->update();
    &updateTerminal($daq->send("HE"));
    return;
}

sub setThreshold {
    my ($self) = @_;
    my $daq = $self->{_daq};

    $threshold[4]->update();

    for ( my $i=0; $i<4; $i ++ ) {
	if ( $threshold[$i] != $oldThresh[$i] ) {
	    $daq->send('TL ' . $i . ' ' . $threshold[$i]);
	    &updateTerminal('TL ' . $i . ' ' . $threshold[$i] . "\n", 'input');
	    $oldThresh[$i] = $threshold[$i];
	}
    }
    &updateTerminal( $daq->send('TL') );
    return;
}

sub resetThreshold {
    my ($self) = @_;
    my $daq = $self->{_daq};

    $threshold[5]->update();

    # Get the current thresholds and set the sliders accordingly
    my $curThresh = $daq->send("TL");
    if ( defined $curThresh ) {
	$curThresh =~ /TL L0=(\d+) L1=(\d+) L2=(\d+) L3=(\d+)/;

	$threshold[0] = (defined $1) ? int($1) : 0;
	$oldThresh[0] = (defined $1) ? int($1) : 0;

	$threshold[1] = (defined $2) ? int($2) : 0;
	$oldThresh[1] = (defined $2) ? int($2) : 0;

	$threshold[2] = (defined $3) ? int($3) : 0;
	$oldThresh[2] = (defined $3) ? int($3) : 0;

	$threshold[3] = (defined $4) ? int($4) : 0;
	$oldThresh[3] = (defined $4) ? int($4) : 0;
    }

    return;
}

sub updateTerminal {
    my ( $text, $tag ) = @_;
    if ( not defined $tag ) {
	$tag = 'output';
    }
    $txt->insert('end', $text, $tag);
    $txt->see('end');
    return;
}

sub exitMain {
    my ($self) = @_;
    $self->{_STAT} = 0;

    if ( $exitBtn ) {
	$exitBtn->update();
    }

    $status->configure(-text => "Cleaning up...");
    $status->update();

    if ( $self->{_UPDID} ) {
	$self->{_UPDID}->cancel();
    }

    my $sock = IO::Socket::INET->new(
	PeerAddr => 'localhost',
	Proto    => 'tcp',
	PeerPort => 8979,
	Block    => 0
	);
    warn "$!\n" unless defined $sock;

    $sock->autoflush(1);
    print $sock "complete\n";
    my $stat = <$sock>;
    $sock->close();

    $status->configure(-text => "Done");
    $status->update();

    $main->destroy();

    return;
}
return 1;
