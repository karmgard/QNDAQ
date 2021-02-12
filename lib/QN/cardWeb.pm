package cardWeb;

use HTTP::Server::Simple::CGI;
use base qw(HTTP::Server::Simple::CGI);

use Time::HiRes qw(usleep);

use IO::Socket;
use IO::Select;

use threads;
use threads::shared;

use QN::ThreadPool;
use QN::ThreadQueue;
use QN::ipFilter;

my $CRLF = "\015\012";  # \r\n
my $CR   = "\015";      # \r
my $LF   = "\012";      # \n

my $webdir;
my $password = undef;

my $cardport;
my $chatport;
my $filter;

sub start {
    my ( $class, $verbose, $passwrd, $webport, $chtport, $crdport, 
	 $workers, $maxClnt, %lists ) = @_;

    $verbose = ( defined($verbose) ) ? $verbose : 0;
    $passwrd = ( defined($passwrd) ) ? $passwrd : undef;
    $webport = ( defined($webport) ) ? $webport : 8008;
    $chtport = ( defined($chtport) ) ? $chtport : 8888;
    $crdport = ( defined($crdport) ) ? $crdport : 8979;
    $workers = ( defined($workers) ) ? $workers : 4;
    $maxClnt = ( defined($maxClnt) ) ? $maxClnt : 25;

    $cardport = $crdport;
    $chatport = $chtport;

    $filter = new ipFilter(%lists);

    # Make sure we know where our files are located
    if ( -d "html" ) {
	$webdir = "html";
    } elsif ( -d $ENV{'OURHOME'} . "/html" ) {
	$webdir = $ENV{'OURHOME'} . "/html";
    } elsif ( -d $ENV{'SYSHOME'} . "/html" ) {
	$webdir = $ENV{'SYSHOME'} . "/html";
    } else {
	warn "Unable to find web page files. No web server for you!\n";
	return undef;
    }

    if ( $passwrd ) {
	$password = $passwrd;
    }

    my $self = {
	_verbose => $verbose,
    };

    bless($self, $class);

    # start the web server on port $webport (8008 by default)
    my $web;
    if ( $webport > 1023 ) {
	$web = $self->startWebServerThread($webport);
    }

    $self->{_webThread}   = $web  if $web  || undef;

    return $self;
}

sub stop {
    my ($self) = @_;
    if ( $self->{_verbose} ) {
	print "Stopping web server\n";
    }

    if ( $self->{_webThread} ) {
	$self->{_webThread}->kill('STOP');
    }

    return 0;
}

sub shutDown {
    my ( $self ) = @_;
    if ( $verbose ) {
	print STDERR "Killing $$\n";
    }
    kill(15,$$);
    exit 0;
}

sub startWebServerThread {
    my ( $self, $webport ) = @_;
    my $webserver = threads->new('startWebServer', $self, $webport)->detach();

    return $webserver;
}

sub startWebServer {
    my ( $self, $webport ) = @_;

    $SIG{'TERM'} = $SIG{'STOP'} = sub { print "Caught kill...\n"; return 0; };

    if ( $self->{_verbose} ) {
	print "Thread " . threads->tid() . " started up as HTTPD\n";
    }

    cardWeb->new($webport)->run();
    return;
}

sub test {
    my ($cgi, $webdir) = @_;

    my $passwd = $cgi->param('passwd');
    my $result = "fail";
    if ( $passwd eq $password ) {
	$result = "success";
    }

    print $cgi->header("Content-type: text/xml");
    print "<data>$result</data>";

    return;
}

sub handle_request {
    my $self = shift;
    my $cgi  = shift;

    my %dispatch = (
	'/'                     => \&servCard,
	'/index.html'           => \&servCard,
	'/403.html'             => \&sendPage,
	'alldone'               => \&shutDown,
	'/alldone'              => \&shutDown,
	'/alldone.html'         => \&shutDown,
	'/style.css'            => \&sendPage,
	'/jquery-latest.min.js' => \&sendPage,
	'/jsocket.js'           => \&sendPage,
	'/jsocket.advanced.js'  => \&sendPage,
	'/functions.js'         => \&sendPage,
	'/swfobject.js'         => \&sendPage,
	'/jsocket.advanced.swf' => \&sendBin,
	'/test.pl'               => \&test
	);

    # If this address isn't allowed into the 
    # DAQ server, toss an error and don't allow 
    # the connection. Just send back a 401
    my $ip = $ENV{'REMOTE_HOST'};
    if ( !$filter->filter($ip) ) {
	print "HTTP/1.0 401 Unauthorized$CRLF";
	print $cgi->header,
	$cgi->start_html('401 Unauthorized'),
	$cgi->h4('You do not have permission to access this server'),
	$cgi->end_html;
	return;
    }

    my $path = $cgi->path_info();
    my $handler = $dispatch{$path};

    if (ref($handler) eq "CODE") {
	print "HTTP/1.0 200 OK$\r\n";
	$handler->($cgi, $webdir);

    } else {
	print "HTTP/1.0 404 Not found\r\n";
	print $cgi->header,
	$cgi->start_html('Not found'),
	$cgi->h1('Not found'),
	$cgi->end_html;
	return;
    }

    return;
}

sub sendBin {
    my ( $cgi, $webDir ) = @_;
    return if !ref $cgi;

    my $path = $webDir . $cgi->path_info();
    print $cgi->header("Content-type: application/x-shockwave-flash");

    open(FH, "<$path" ) || warn "Unable to open $path: $!";
    binmode FH;

    while ( read(FH, my $buffer, 4096) ) {
	print $buffer;
    }

}

sub sendPage {
    my ( $cgi, $webDir ) = @_;
    return if !ref $cgi;

    my $path = $webDir . $cgi->path_info();

    if ( $path =~ /\.js/ ) {
	print $cgi->header("Content-type: text/javascript");
    } elsif ( $path =~ /\.html/ ) {
	print $cgi->header;
    }

    my $edit = ($path =~ /functions\.js/) ? 1 : 0;

    # Auto edit the poert numbers in the web page before we send it along
    open(FH, "<$path") || die "Unable to open $path: $!\n";
    while ( my $read = <FH> ) {
	if ( $edit ) {
	    if ( $read =~ /var cardPort/ ) {
		my $update = "cardPort = " . $cardport . ";";
		$read =~ s/cardPort.*$/$update/;
	    } elsif ( $read =~ /var chatPort/ ) {
		my $update = "chatPort = " . $chatport . ";";
		$read =~ s/chatPort.*$/$update/;
	    }
	}
	print $read;
    }
    close(FH);
}

sub servCard {
    my ($cgi, $webDir) = @_;
    return if !ref $cgi;

    my $path = $cgi->path_info();

    if ( $path eq "/" ) {
	$path = $webDir . "/index.html";
    } else {
	$path = $webDir . $path;
    }

    my $header = $cgi->start_html(
	-title => "QuarkNet Cosmic Ray Detector",
	-dtd => "-//W3C//DTD XHTML 1.0 Strict//EN\n\thttp://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd",
	-style => {-src=>'style.css'},
	-script => [
	     {-language=>'JavaScript', -src => 'jquery-latest.min.js'},
	     {-language=>'JavaScript', -src => 'jsocket.js'},
	     {-language=>'JavaScript', -src => 'jsocket.advanced.js'},
	     {-language=>'JavaScript', -src => 'functions.js'},
	     {-language=>'JavaScript', -src => 'swfobject.js'}
	],
	-onLoad => 'onLoad()', -onUnLoad => 'unLoad()'
	);

    open(FH, "<$path") || die "Can't open $path: $!\n";
    while (my $read = <FH>) {
	last if $read =~ /<body/;
    }

    my $body = "";
    while (my $read = <FH>) {
	last if $read =~ /<\/body/;
	$body .= $read;
    }
    close(FH);
    my $trailer = $cgi->end_html();
    print $cgi->header, $header, $body, $trailer . "\n\n";

    return;
}

return 1;
