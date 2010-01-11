#!/usr/bin/perl -wT
################################################################################
##
## See end of script for comments and 'pod2man telnetbbs | nroff -man' to
## view man page or pod2text telnetbbs for plain text.
##
##   Nicholas DeClario <nick@declario.com>
##   October 2009
##	$Id: telnetbbs.pl,v 1.3 2010-01-11 05:02:27 nick Exp $
##
################################################################################
BEGIN {
        delete @ENV{qw(IFS CDPATH ENV BASH_ENV PATH)};
        $ENV{PATH} = "/bin:/usr/bin";
        $|++;
# Flip this back on for more detailed error reporting
#        $SIG{__DIE__} = sub { require Carp; Carp::confess(@_); }
      }

use strict;
use Getopt::Long;
use Pod::Usage;
use Data::Dumper;
use POSIX qw/ mkfifo /;
use IO::File;
use Socket;
use IO::Socket::INET;
use Time::HiRes qw/ sleep setitimer ITIMER_REAL time /;
use threads;
use threads::shared;

##
## Fetch our command line options
##
my %opts    = &fetchOptions( );
my $pidFile = "/var/run/telnetbbs.pid";
my @nodes   = ( );
my $EOL     = "\015\012";

## 
## These will be moved in to a config file
##
my $DISPLAY  = ":1018.0";
my $BBS_NAME = "Hell's Dominion BBS";
my $BBS_NODE = 0;
my $DBCONF   = "/tmp/dosbox-__NODE__.conf";
my $BBS_CMD  = "DISPLAY=$DISPLAY /usr/bin/dosbox -conf ";
my $LOG      = "/var/log/bbs.log";
my $MAX_NODE = 6;
my $DOSBOXT  = "dosbox.conf.template";
my $BASE_PORT = 5000;

##
## Check that we are 'root' 
##
die( "Must be root user to run this.\n" )
	if ( getpwuid( $> ) ne "root" );

##
## Check for a PID
##
exit( 255 ) if ( ! &checkPID( $pidFile ) );

##
## Lets keep an eye on the forked children our network socket will be using
##
$SIG{CHLD} = 'IGNORE';

##
## Catch any type of kill signals so that we may cleanly shutdown.  These
## include 'kill', 'kill -HUP' and a 'CTRL-C' from the keyboard.
##
local $SIG{HUP}  = $SIG{INT} = $SIG{TERM} = \&shutdown;

##
## Open the Log
##
#open LOG, ">>$LOG";
&logmsg( "Starting telnetbbs server" );

##
## Start the network server
##
my $netThread = threads->create( \&startNetServer );

while( 1 ) { sleep 1; }

##
## If we made it here, the main loop died, lets shutdown
##
&shutdown( );

###############################################################################
###############################################################################
##
## Sub-routines begin here
##
###############################################################################
###############################################################################

sub logmsg { print "$0 $$ ", scalar localtime, ":@_\n" }

###############################################################################
## startNetServer( );
##
##  We want to open the next free port when an incoming connection to the
##  main port is made.  We need to set that up here.
##
###############################################################################
sub startNetServer 
{
	my $hostConnection;
	my $childPID;
	my $port = $opts{'port'} || 23;

	my $server = IO::Socket::INET->new( 
			LocalPort => $port,
			Type	  => SOCK_STREAM,
			Proto	  => 'tcp',
			Reuse	  => 1,
			Listen	  => 1,
		) or die "Couldn't create socket on port $port: $!\n";
	
	&logmsg( "Listening on port $port" );

        ##
        ## We want to fork our connection when it's made so that we are ready
        ## to accept other incoming connections.
        ##
	REQUEST: while( $hostConnection = $server->accept( ) )
	{
		## 
		## Find the next available node
		##
		my $node = 0;
		foreach (1 .. $MAX_NODE)
		{
			next if ( $node );
			if ( ! $nodes[$_] ) 
			{
				$node = $BBS_NODE = $_;
				$nodes[$_]++;
			}
		}

		##
		## Create our dosbox config
		##
		open( DBT, "<$DOSBOXT" );
			my @dbt = <DBT>;
		close( DBT );
		
		my $bpn = $BASE_PORT + $BBS_NODE;
		$DBCONF =~ s/__NODE__/$BBS_NODE/g;
		open( DBC, ">$DBCONF" );
		foreach( @dbt ) 
		{
			$_ =~ s/__NODE__/$BBS_NODE/g;
			$_ =~ s/__LISTEN_PORT__/$bpn/g;
			print DBC $_;
		}
		close( DBC );

		&logmsg( "Connecting on node $BBS_NODE\n" );

		my $kidpid;
		my $line;

		if( $childPID = fork( ) ) {
			close( $hostConnection );
			next REQUEST;
		}
		defined( $childPID ) || die( "Cannot fork: $!\n" );

		##
		## Default file descriptor to the client and turn on autoflush
		##
		$hostConnection->autoflush( 1 );

		print $hostConnection "Welcome to $BBS_NAME!" . $EOL;

		##
		if ( ! $BBS_NODE ) 
		{
			print $hostConnection "No available nodes.  Try again later.".$EOL;
			exit;
		}

		print $hostConnection "Starting BBS on node $BBS_NODE...$EOL";

		##
		## Launch BBS via dosbox
		##
		my $bbsPID = fork( );
		if ( $bbsPID ) 
		{
			my $cmd = $BBS_CMD . $DBCONF;
			exec( $cmd );
			exit;
		}

		##
		## We wait for dosbox to start and the BBS to start
		## There really should be a better way to determine this
		##
		sleep 5;

		##
		## Create connection to BBS
		##
		my $bbs = IO::Socket::INET->new (
				PeerAddr 	=> 'localhost',
				Type	 	=> SOCK_STREAM,
				PeerPort	=> $bpn,
				Proto		=> 'tcp',
			) || die "Could not open BBS socket: $!\n";
		$bbs->autoflush( 1 );
		die "Can't fork BBS connection: $!\n" 
			unless defined( $kidpid = fork( ) );

		if ( $kidpid ) 
		{
			my $byte;
			while ( sysread( $bbs, $byte, 1 ) == 1 ) 
			{
				print $hostConnection $byte;
			}
			kill( "TERM" => $childPID );
		}
		else 
		{
			my $byte;
			while( sysread( $hostConnection, $byte, 1 ) == 1 )
			{
				print $bbs $byte;
			}
		}

		unlink( $DBCONF );
	}
	close( $hostConnection );
	exit;

#	close( $server );
}

###############################################################################
##
## shutdown( $signame );
##
##  Call our shutdown routine which cleanly kills all the child processes 
##  and shuts down.  Optionally, if a kill signal was received, it will be
##  displayed.
##
###############################################################################
sub shutdown 
{
	my $signame = shift || 0;

	&logmsg( "$0: Shutdown (SIG$signame) received.\n" )
		if( $signame );
	
	##
	## Close Log
	##
	close( LOG );

	##	
	## Remove the PID
	##
	unlink( $pidFile );

	##
	## Wait for the thread to shutdown
	##
#	$netThread->detach( );	

	##
	## And time to exit
	##
	&POSIX::_exit( 0 );
}

###############################################################################
##
## my $result = checkPID( $pidFile );
##
##   We need to see if there is a PID file, if so if the PID inside is still
## actually running, if not, re-create the PID file with the new PID.  
## If there is no PID file to begin with, we create one.
##
## If this process is successfull a non-zero value is returned.
##
###############################################################################
sub checkPID
{
	my $pidFile = shift || return 0;
	my $pid     = 0;

        ##
        ## If there is no PID file, create it.
        ##
        if ( ! stat( $pidFile ) ) 
	{
            open PF, ">$pidFile" || return 0;
                print PF $$;
            close( PF );

            return 1;
        }
        ##
        ## We have a PID file.  If the process does not actually exist, then
        ## delete the PID file.
        ##
        else 
	{
        	open PIDFILE, "<$pidFile" || 
			die( "Failed ot open PID file: $!\n" );
          		$pid = <PIDFILE>;
        	close( PIDFILE );

		##
		## Unlink the file if the process doesn't exist 
		## and continue with execution
		##
		if ( &processExists( $pid, $0 ) ) 
		{
			unlink( $pidFile );
			open PF, ">$pidFile" || return 0;
				print PF $$ . "\n";
			close( PF );

			return 2;
		}
            	return 0;
        }
}

###############################################################################
##
## sub processExists( );
##
##	Check the '/proc' file system for the process ID number listed in the
##  PID file.  '/proc/$PID/cmdline' will be compared to the running process
##  name.  If the process ID does exist but the name does not match we assume
##  it's a dead PID file.
##
###############################################################################
sub processExists 
{
	my $pid   = shift || return 0;
	my $pname = shift || return 0;

	##
	## If the directory doesn't exist, there is no way the 
	## process is running
	##
	return 0 if ( ! -f "/proc/$pid" );

	##
	## However, if the directory does exist, we need to confirm that it is
	## indeed the process we are looking.
	##
	open CMD, "</proc/$pid/cmdline";
		my $cmd = <CMD>;
	close( CMD );

	##
	## Filter out leading PATH information
	##
	$pname =~ s/^\.\///;
	$cmd   =~ s/.*\/(.*)/$1/;

	##
	## if we found the process, return 1
	##
	return 1 if ( $cmd =~ m/$pname/ );

	return 0;
}


###############################################################################
##
## &fetchOptions( );
##
##      Grab our command line arguments and toss them in to a hash
##
###############################################################################
sub fetchOptions {
        my %opts;

        &GetOptions(
                        "help|?"        => \$opts{'help'},
                        "man"           => \$opts{'man'},
			"port:i"	=> \$opts{'port'},
                   ) || &pod2usage( );
        &pod2usage( ) if defined $opts{'help'};
        &pod2usage( { -verbose => 2, -input => \*DATA } ) if defined $opts{'man'};

        return %opts;
}

__END__

=head1 NAME

telnetbbs.pl - A telnet server designed to launch a multi-node BBS.

=head1 SYNOPSIS

telnetbbs.pl [options]

 Options:
        --help,?        Display the basic help menu
        --man,m         Display the detailed man page
	--port,p	Port to listen on, default 23.

=head1 DESCRIPTION

=head1 HISTORY

=head1 AUTHOR

Nicholas DeClario <nick@declario.com>

=head1 BUGS

This is a work in progress.  Please report all bugs to the author.

=head1 SEE ALSO

=head1 COPYRIGHT

=cut
