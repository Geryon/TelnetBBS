#!/usr/bin/perl -wT
################################################################################
##
## See end of script for comments and 'pod2man telnetbbs | nroff -man' to
## view man page or pod2text telnetbbs for plain text.
##
##   Nicholas DeClario <nick@declario.com>
##   October 2009
##	$Id: telnetbbs.pl,v 1.7 2010-12-16 14:24:25 nick Exp $
##
################################################################################
BEGIN {
        delete @ENV{qw(IFS CDPATH ENV BASH_ENV PATH)};
        $ENV{PATH} = "/bin:/usr/bin";
        $|++;
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
## Fetch our command line and configuration options
##
my %opts    = &fetchOptions( );
my %cfg     = &fetchConfig( );
my $EOL     = "\015\012";

## 
## These are read in from the config file
##
my $BBS_NODE  = 0;
my $pidFile   = $cfg{'pidfile'}    || "/tmp/telnetbbs.pid";
my $port      = $opts{'port'}      || $cfg{'port'} || 23;
my $DISPLAY   = $cfg{'display'}    || ":0.0";
my $BBS_NAME  = $cfg{'bbs_name'}   || "Hell's Dominion BBS";
my $DBCONF    = $cfg{'dosbox_cfg'} || "/tmp/dosbox-__NODE__.conf";
my $BBS_CMD   = $cfg{'bbs_cmd'}    || "DISPLAY=$DISPLAY /usr/bin/dosbox -conf ";
my $LOGGING   = $cfg{'logging'}    || 0;
my $LOG       = $cfg{'log_path'}   || "/tmp/bbs.log";
my $MAX_NODE  = $cfg{'nodes'}      || 1;
my $DOSBOXT   = $cfg{'dosboxt'}    || "dosbox.conf.template";
my $BASE_PORT = $cfg{'base_port'}  || 7000;
my $LOCK_PATH = $cfg{'lock_path'}  || "/tmp";

##
## Check that we are 'root' 
##
die( "Must be root user to run this.\n" )
	if ( getpwuid( $> ) ne "root" && $port < 1023 );

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
open LOG, ">>$LOG" if ( $LOGGING );
&logmsg( "Starting telnetbbs server" );

##
## Display running information
##
&display_config_and_options( \%opts, "Options" );
&display_config_and_options( \%cfg, "Configuration" );

##
## Start the network server
##
my $netThread = threads->create( \&startNetServer( ) );


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

sub logmsg 
{ 
	my $message = "$0 $$ " . scalar( localtime( ) ) . ":@_\n";
	print STDOUT $message;
	print LOG $message if ( $LOGGING );
}


###############################################################################
###############################################################################
sub display_config_and_options
{
	my $hr    = shift || 0;
	my $name  = shift || "Unknown";
	my $title = "Displaying $name\n";

	return $hr if ( ! $hr );

	print LOG $title . Dumper( $hr ) if ( $LOGGING );
	print STDOUT $title . Dumper( $hr ) if ( $opts{'verbose'});
}

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
	my @nodes = ( );

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
		my $lock_file = "";
		foreach (1 .. $MAX_NODE)
		{
			next if ( -f $LOCK_PATH."/".$BBS_NAME."_node".$_.".lock" );

			##
			## Create node lock file
			##
			$lock_file = $LOCK_PATH."/".$BBS_NAME."_node".$_.".lock";
			open LOCK, ">$lock_file";
			close( LOCK );
			$node = $BBS_NODE = $_;
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

		select $hostConnection;

		##
		## Default file descriptor to the client and turn on autoflush
		##
		$hostConnection->autoflush( 1 );

		print "Welcome to $BBS_NAME!" . $EOL;

		##
		if ( ! $lock_file ) 
		{
			print "No available nodes.  Try again later.".$EOL;
			exit;
		}

		print "Starting BBS on node $BBS_NODE...$EOL";

		##
		## Launch BBS via dosbox
		##
		my $bbsPID = fork( );
		if ( $bbsPID ) 
		{
			select STDOUT;
			my $cmd = $BBS_CMD . $DBCONF;
			system( $cmd );
			print "Shutting down node $BBS_NODE\n";
			##
			## Remove Lock
			##	
			unlink( $lock_file );
			unlink( $DBCONF );
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
			$nodes[$BBS_NODE] = 0;
			kill( "TERM" => $kidpid );
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

	select STDOUT;

	&logmsg( "$0: Shutdown (SIG$signame) received.\n" )
		if( $signame );
	
	##
	## Close Log
	##
	close( LOG ) if ( $LOGGING );

	##	
	## Remove the PID
	##
	unlink( $pidFile );

	##
	## Remove node lock files
	##
	foreach (1 .. $MAX_NODE)
	{
		my $node_lock = $LOCK_PATH."/".$BBS_NAME."_node".$_.".lock";
		unlink( $node_lock ) if ( -f $node_lock );
	}

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
###############################################################################
sub fetchConfig 
{
	my %conf = ( );
	my $cf   = &findConfig;

	if ( $cf ) 
	{
		open( CONF, "<$cf" ) or die ( "Error opening $cf: $!\n" );
			while( <CONF> ) 
			{
				next if ( $_ =~ m/^#/ );
				if ( $_ =~ m/(.*?)=(.*)/ )
				{
					my $k = $1; my $v = $2;
					$k =~ s/\s+//;
					$v =~ s/\s+//;
					$conf{$k} = $v;
				}
			}
		close( CONF );
	}

	return %conf;
}

###############################################################################
###############################################################################
sub findConfig
{
	my $cf    = 0;
	my @paths = qw| ./ ./.telnetbbs /etc /usr/local/etc |;

	return $opts{'config'} if defined $opts{'config'};

	foreach ( @paths ) 
	{
		my $fn = $_ . "/telnetbbs.conf";
		return $fn if ( -f $fn );
	}

	return $cf;
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
			"config:s"	=> \$opts{'config'},
                        "help|?"        => \$opts{'help'},
                        "man"           => \$opts{'man'},
			"port:i"	=> \$opts{'port'},
			"verbose"	=> \$opts{'verbose'},
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
	--config,c	Specify the configuration file to use
        --help,?        Display the basic help menu
        --man,m         Display the detailed man page
	--port,p	Port to listen on, default 23.
	--verbose,v	Enable verbose output

=head1 DESCRIPTION

=head1 HISTORY

=head1 AUTHOR

Nicholas DeClario <nick@declario.com>

=head1 BUGS

This is a work in progress.  Please report all bugs to the author.

=head1 SEE ALSO

=head1 COPYRIGHT

=cut
