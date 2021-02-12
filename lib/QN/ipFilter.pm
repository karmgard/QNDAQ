package ipFilter;

use Net::CIDR;
use Socket;
use Net::DNS;
use Net::Whois::Raw qw( whois );

sub new {
    my ( $class, %lists ) = @_;

    @whitelist = @{$lists{'whitelist'}};
    @blacklist = @{$lists{'blacklist'}};
    @bdnlist   = ();
    @wdnlist   = ();

    #----------------------------------------------------------#
    #    Since we should probably allow users to send in       #
    # system names in standard network format in addition to   #
    # the standard dotted decimal notation... massage the list #
    # (both of them) to do a DNSish lookup on names and add    #
    # the IP addresses (there can be more than one) to them    #
    # in place of the name. Not yet fully developed for a name #
    # range like *.fnal.gov ... but we're getting there        #
    #----------------------------------------------------------#
    for ( my $j=0; $j<=1; $j++ ) {
	my @list   = ($j) ? @blacklist : @whitelist;
	my @dnlist = ($j) ? @bdnlist   : @wdnlist;

	for ( my $i=0; $i<=$#list; $i++ ) {
	    my $address = $list[$i];

	    if ( $address =~ /\// ) {
		$address =~ s/\/.*$//;
	    }

	    if ( $address =~ /\*/ ) {
		$address =~ s/\*\.//g;
		$address =~ s/\*//g;

		# See if we can resolve this
		my $range = &getNetworkFromName(undef, $address);
		if ( $range ) {
		    if ( $verbose ) {
			print "Replacing $list[$i] with $range\n";
		    }
		    $list[$i] = $range;

		} else {
		    # Remove this address
		    splice( @list, $i, 1 );
		    $i--;

		    # And add it to our RegExp list
		    push(@dnlist, $address);
		}

		next;

	    } elsif ( $address !~ /\d+\.\d+\.\d+\.\d+/ ) {
		# Get all addresses for this host
		my @addresses = gethostbyname($address) 
		    or warn "Can't resolve $address: $!\n";

		@addresses = map { inet_ntoa($_) } @addresses[4 .. $#addresses];

		# Remove this address
		splice( @list, $i, 1 );
		$i--;

		# And add the results of the address lookup
		foreach my $lookup (@addresses) {
		    push(@list, $lookup);
		}
	    }
	} # End for ( my $i=0; $i<=$#list; $i++ )

	# OK... the white/black lists are managable....
	# Now put them into standard CDIR range notation
	my @newlist = ();
	my $address;
	my $mask;
	foreach my $range (@list) {

	    if ( index($range, "/") > -1 ) {
		($address,$mask) = split(/\//, $range);

		if ( index($mask, ".") > -1 ) {
		    push(@newlist, Net::CIDR::addrandmask2cidr($address, $mask));
		} else {
		    push(@newlist, Net::CIDR::cidradd("$address/$mask"));
		}

	    } elsif ( index($range, "-") > -1 ) {
		push(@newlist, Net::CIDR::cidradd($range));

	    } else {
		push(@newlist, Net::CIDR::cidradd("$range/32"));
	    }

	} # End foreach my $range (@list)

	# Copy the modified list back to the original
	if ( $j ) {
	    @blacklist = @newlist;
	    @bdnlist   = @dnlist;
	} else {
	    @whitelist = @newlist;
	    @wdnlist   = @dnlist;
	}

    } # End for ( my $j=0; $j<=1; $j++ )

    my $self = {
	_whitelist => \@whitelist,
	_wdnlist   => \@wdnlist,  
	_blacklist => \@blacklist,
	_bdnlist   => \@bdnlist
    };

    bless( $self, $class );
    return $self;
}

#
# Weird hack to try and grab a network range 
# given a name... fnal.gov => 131.225.0.0/16
#
sub getNetworkFromName {
    my ( $self, $network ) = @_;

    my $res   = Net::DNS::Resolver->new;
    my $query = $res->search($network);

    if ($query) {
	foreach my $rr ($query->answer) {
	    next unless $rr->type eq "A";

	    my $s = whois($rr->address);
	    $s =~ /CIDR: .* (\d+\.\d+\.\d+\.\d+\/\d+)/;
	    if ( defined($1) ) {
		return $1;
	    }
	}

    } else {
	warn "query failed: ", $res->errorstring, "\n";

	# Fall down go boom... Try sticking a www in there
	$query = $res->search("www." . $network);
	if ( $query ) {
	    foreach my $rr ($query->answer) {
		next unless $rr->type eq "A";

		my $s = whois($rr->address);
		$s =~ /CIDR: .* (\d+\.\d+\.\d+\.\d+\/\d+)/;
		if ( defined($1) ) {
		    return $1;
		}
	    }	
	} else {
	    warn "Unable to resolve network $network ", $res->errorstring, "\n";
	}
    }

    return undef;
}

sub makeCDIR {
    my ( $self, $range ) = @_;

    my $address;
    my $mask;

    if ( index($range, "/") > -1 ) {
	($address,$mask) = split(/\//, $range);

	if ( index($mask, ".") > -1 ) {
	    return Net::CIDR::addrandmask2cidr($address, $mask);
	} else {
	    return Net::CIDR::cidradd("$address/$mask");
	}

    } elsif ( index($range, "-") > -1 ) {
	return Net::CIDR::cidradd($range);
	
    } else {
	return Net::CIDR::cidradd("$range/32");
    }

    return undef;
}

sub dumpLists {
    my ( $self ) = @_;

    if ( scalar $self->{_whitelist} > -1 ) {
	print "White listed addresses : \n\t";
	print join("\n\t", @{$self->{_whitelist}}) . "\n\t";
	print join("\n\t", @{$self->{_wdnlist}}) . "\n";
    }

    if ( scalar $self->{_blacklist} > -1 ) {
	print "Black listed addresses : \n\t";
	print join("\n\t", @{$self->{_blacklist}}) . "\n\t";
	print join("\n\t", @{$self->{_bdnlist}}) . "\n";
    }
    return;
}

sub addToWhiteList {
    my ( $self, $allowed ) = @_;
    if ( $allowed !~ /\*/ ) {
	push(@{$self->{_whitelist}}, $self->makeCDIR($allowed));
    } else {
	$allowed =~ s/\*\.//g;
	$allowed =~ s/\*//g;
	push(@{$self->{_wdnlist}}, $allowed);
    }
    return;
}

sub addToBlackList {
    my ( $self, $forbidden ) = @_;
    if ( $forbidden !~ /\*/ ) {
	push(@{$self->{_blacklist}}, $self->makeCDIR($forbidden));
    } else {
	$forbidden =~ s/\*\.//g;
	$forbidden =~ s/\*//g;
	push(@{$self->{_bdnlist}}, $forbidden);
    }
    return;
}

sub removeFromWhiteList {
    my ( $self, $remove ) = @_;

    if ( $remove !~ /\*/ ) {
	for ( my $i=0; $i<scalar(@{$self->{_whitelist}}); $i++ ) {
	    my $range = $self->{_whitelist}[$i];

	    if ( $range =~ /$remove/ ) {
		splice(@{$self->{_whitelist}}, $i, 1);
		last;
	    }
	}
    } else {
	$remove =~ s/\*\.//g;
	$remove =~ s/\*//g;
	for ( my $i=0; $i<scalar(@{$self->{_wdnlist}}); $i++ ) {
	    my $range = $self->{_wdnlist}[$i];

	    if ( $range =~ /$remove/ ) {
		splice(@{$self->{_wdnlist}}, $i, 1);
		last;
	    }
	}
    }
    
    return;
}

sub removeFromBlackList {
    my ( $self, $remove ) = @_;

    if ( $remove !~ /\*/ ) {
	for ( my $i=0; $i<scalar(@{$self->{_blacklist}}); $i++ ) {
	    my $range = $self->{_blacklist}[$i];

	    if ( $range =~ /$remove/ ) {
		splice(@{$self->{_blacklist}}, $i, 1);
		last;
	    }
	}
    } else {
	$remove =~ s/\*\.//g;
	$remove =~ s/\*//g;
	for ( my $i=0; $i<scalar(@{$self->{_bdnlist}}); $i++ ) {
	    my $range = $self->{_bdnlist}[$i];

	    if ( $range =~ /$remove/ ) {
		splice(@{$self->{_bdnlist}}, $i, 1);
		last;
	    }
	}
    }
    
    return;
}

sub filter {
    my ( $self, $ip ) = @_;

    if ( $ip eq '127.0.0.1' ) {
	# Always allow localhost
	return 1;
    }

    ################ White list ##################################
    if ( scalar($self->{_whitelist}) > -1 ) {

	# check the allowed hosts
	if ( !Net::CIDR::cidrlookup($ip, @{$self->{_whitelist}}) ) {

	    if ( scalar(@{$self->{_whitelist}}) ) {

		# Not on the nice simple IP range list... 
		# See if it's in our domain lookup
		my $hostname = gethostbyaddr(inet_aton($ip),AF_INET);

		if ( $verbose ) {
		    print "Whitelist checking $hostname against DNS lookups...";
		}

		if ( defined($hostname) ) {
		    my $hostreg = join("|", @{$self->{_wdnlist}});
		    if ( $hostname !~ /$hostreg/ ) {
			return 0;
		    }
		}
	    
		# If you're not on the list... you're not cool enough
		# to be inside... Socket programming for bouncers
		if ( $verbose ) {
		    print STDERR "Denied. Not on whitelist\n";
		}
		return 0;
	    }
	}
    }
    #------------------------------------------------------------#
    # So, we checked the white list, and there either wasn't one #
    # or this host was on it... now check it against the black   #
    # black list for fine graine control.                        #
    #------------------------------------------------------------#
    if ( scalar($self->{_blacklist}) > -1 ) {

	if ( Net::CIDR::cidrlookup($ip, @{$self->{_blacklist}}) ) {
	    # You must be a bad bad hacker... no way you're going in
	    # Unless, of course, you've figured out a way to hack in
	    # past this ridiculously simple security setup...
	    if ( $verbose ) {
		print STDERR "Denied. Blacklisted\n";
	    }
	    return 0;

	} elsif ( scalar(@{$self->{_bdnlist}}) ) {
	    # Not on the nice simple IP range list... 
	    # See if it's in our domain lookup

	    my $hostname = gethostbyaddr(inet_aton($ip),AF_INET);
	    if ( $verbose ) {
		print STDERR "Blacklist checking $hostname against DNS matching\n";
	    }

	    my $hostreg = join("|", @{$self->{_bdnlist}});
	    if ( $hostname =~ /$hostreg/ ) {
		return 0;
	    }
	}
    }

    # If they made it past the white list & 
    # the black list... they're allowed in
    return 1;
}

return 1;
