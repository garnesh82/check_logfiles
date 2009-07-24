package main;

use strict;
use utf8;
use File::Basename;
use File::Find;
use Getopt::Long;

use constant OK => 0;
use constant WARNING => 1;
use constant CRITICAL => 2;
use constant UNKNOWN => 3;

Getopt::Long::Configure qw(no_ignore_case); # compatibility with old perls
use vars qw (%commandline);
my @cfgfiles = ();
my $needs_restart = 0;
my $enough_info = 0;

my $plugin_revision = '$Revision: 1.0 $ ';
my $progname = basename($0);

sub print_version {
  printf "%s v#PACKAGE_VERSION#\n", basename($0);
}

sub print_help {
  print <<EOTXT;
This Nagios Plugin comes with absolutely NO WARRANTY. You may use
it on your own risk!
Copyright by ConSol Software GmbH, Gerhard Lausser.

This plugin looks for patterns in logfiles, even in those who were rotated
since the last run of this plugin.

You can find the complete documentation at 
http://www.consol.com/opensource/nagios/check-logfiles
or
http://www.consol.de/opensource/nagios/check-logfiles

Usage: check_logfiles [-t timeout] -f <configfile>

The configfile looks like this:

\$seekfilesdir = '/opt/nagios/var/tmp';
# where the state information will be saved.

\$protocolsdir = '/opt/nagios/var/tmp';
# where protocols with found patterns will be stored.

\$scriptpath = '/opt/nagios/var/tmp';
# where scripts will be searched for.

\$MACROS = \{ CL_DISK01 => "/dev/dsk/c0d1", CL_DISK02 => "/dev/dsk/c0d2" \};

\@searches = (
  {
    tag => 'temperature',
    logfile => '/var/adm/syslog/syslog.log',
    rotation => 'bmwhpux',
    criticalpatterns => ['OVERTEMP_EMERG', 'Power supply failed'],
    warningpatterns => ['OVERTEMP_CRIT', 'Corrected ECC Error'],
    options => 'script,protocol,nocount',
    script => 'sendnsca_cmd'
  },
  {
    tag => 'scsi',
    logfile => '/var/adm/messages',
    rotation => 'solaris',
    criticalpatterns => 'Sense Key: Not Ready',
    criticalexceptions => 'Sense Key: Not Ready /dev/testdisk',
    options => 'noprotocol'
  },
  {
    tag => 'logins',
    logfile => '/var/adm/messages',
    rotation => 'solaris',
    criticalpatterns => ['illegal key', 'read error.*\$CL_DISK01\$'],
    criticalthreshold => 4
    warningpatterns => ['read error.*\$CL_DISK02\$'],
  }
);

EOTXT
}

sub print_usage {
  print <<EOTXT;
Usage: check_logfiles [-t timeout] -f <configfile> [--searches=tag1,tag2,...]
       check_logfiles [-t timeout] --logfile=<logfile> --tag=<tag> --rotation=<rotation>
                      --criticalpattern=<regexp> --warningpattern=<regexp>

EOTXT
}

%commandline = ();
my @params = (
    "timeout|t=i",
    "version|V",
    "help|h",
    "debug|d",
    "verbose|v",
    #
    # 
    #
    "environment|e=s%",
    "daemon:i",
    "report=s",
    "reset",
    #
    #
    #
    "install",
    "deinstall",
    "service=s",
    "username=s",
    "password=s",
    #
    # which searches
    #
    "config|f=s",
    "configdir|F=s",
    "searches=s",
    "selectedsearches=s",
    #
    # globals
    #
    "seekfilesdir=s",
    "protocolsdir=s",
    "protocolsretention=i",
    "macro=s%",
    #
    # search
    #
    "template=s",
    "tag=s",
    "logfile=s",
    "rotation=s",
    "tivolipattern=s",
    "criticalpattern=s",
    "criticalexception=s",
    "warningpattern=s",
    "warningexception=s",
    "okpattern=s",
    "type=s",
    "archivedir=s",
    #
    # search options
    #
    "noprotocol",
    "nocase",
    "nologfilenocry",
    "maxlength=i",
    "syslogserver",
    "syslogclient=s",
    "sticky:s",
    "noperfdata",
    "winwarncrit",
    "lookback=s",
    "context=i",
    "criticalthreshold=i",
    "warningthreshold=i",
    "encoding=s",
);
if (! GetOptions(\%commandline, @params)) {
  print_help();
  exit $ERRORS{UNKNOWN};
} 

if (exists $commandline{version}) {
  print_version();
  exit UNKNOWN;
}

if (exists $commandline{help}) {
  print_help();
  exit UNKNOWN;
}

if (exists $commandline{config}) {
  $enough_info = 1;
} elsif (exists $commandline{configdir}) {
  $enough_info = 1;
} elsif (exists $commandline{logfile}) {
  $enough_info = 1;
} elsif (exists $commandline{type} && $commandline{type} =~ /^eventlog/) {
  $enough_info = 1;
} elsif (exists $commandline{deinstall}) {
  $commandline{type} = 'dummy';
  $enough_info = 1;
}
if (exists $commandline{lookback}) {
  if ($commandline{lookback} =~ /^(\d+)(s|m|h|d)$/) {
    if ($2 eq 's') {
      $commandline{lookback} = $1;
    } elsif ($2 eq 'm') {
      $commandline{lookback} = $1 * 60;
    } elsif ($2 eq 'h') {
      $commandline{lookback} = $1 * 60 * 60;
    } elsif ($2 eq 'd') {
      $commandline{lookback} = $1 * 60 * 60 *24;
    }
  } else {
    printf STDERR "illegal time interval (must be <number>[s|m|h|d]\n";
    print_usage();
    exit UNKNOWN;
  }
}

if (! $enough_info) {
  print_usage();
  exit UNKNOWN;
}

if (exists $commandline{daemon}) {
  my @newargv = ();
  foreach my $option (keys %commandline) {
    if (grep { /^$option/ && /=/ } @params) {
      push(@newargv, sprintf "--%s", $option);
      push(@newargv, sprintf "%s", $commandline{$option});
    } else {
      push(@newargv, sprintf "--%s", $option);
    }
  }
  $0 = 'check_logfiles '.join(' ', @newargv);
  if (! $commandline{daemon}) {
    $commandline{daemon} = 300;
  }
}
if (exists $commandline{environment}) {
  # if the desired environment variable values are different from
  # the environment of this running script, then a restart is necessary.
  # because setting $ENV does _not_ change the environment of the running script.
  foreach (keys %{$commandline{environment}}) {
    if ((! $ENV{$_}) || ($ENV{$_} ne $commandline{environment}->{$_})) {
      $needs_restart = 1;
      $ENV{$_} = $commandline{environment}->{$_};
    }
  }
}
if ($needs_restart) {
  my @newargv = ();
  foreach my $option (keys %commandline) {
    if (grep { /^$option/ && /=/ } @params) {
      if (ref ($commandline{$option}) eq "HASH") {
        foreach (keys %{$commandline{$option}}) {
          push(@newargv, sprintf "--%s", $option);
          push(@newargv, sprintf "%s=%s", $_, $commandline{$option}->{$_});
        }
      } else {
        push(@newargv, sprintf "--%s", $option);
        push(@newargv, sprintf "%s", $commandline{$option});
      }
    } else {
      push(@newargv, sprintf "--%s", $option);
    }
  }
  exec $0, @newargv;
  # this makes sure that even a SHLIB or LD_LIBRARY_PATH are set correctly
  # when the perl interpreter starts. Setting them during runtime does not
  # help loading e.g. libclntsh.so
  exit;
}

if (exists $commandline{configdir}) {
  sub eachFile {
    my $filename = $_;
    my $fullpath = $File::Find::name;
    #remember that File::Find changes your CWD, 
    #so you can call open with just $_
    if ((-f $filename) && ($filename =~ /\.(cfg|conf)$/)) { 
      push(@cfgfiles, $fullpath);
    }
  }
  find (\&eachFile, $commandline{configdir});
  @cfgfiles = sort { $a cmp $b } @cfgfiles;
}
if (exists $commandline{config}) {
  # -f is always first
  unshift(@cfgfiles, $commandline{config});
}
if (scalar(@cfgfiles) == 1) {
  $commandline{config} = $cfgfiles[0];
} elsif (scalar(@cfgfiles) > 1) {
  $commandline{config} = \@cfgfiles;
}
if (exists $commandline{searches}) {
  $commandline{selectedsearches} = $commandline{searches};
}
if (! exists $commandline{selectedsearches}) {
  $commandline{selectedsearches} = "";
}
if (exists $commandline{type}) {
  my ($type, $details) = split(":", $commandline{type});
}
if (exists $commandline{criticalpattern}) {
  $commandline{criticalpattern} = '.*' if
      $commandline{criticalpattern} eq 'match_them_all';
  delete $commandline{criticalpattern} if
      $commandline{criticalpattern} eq 'match_never_ever';
}
if (exists $commandline{warningpattern}) {
  $commandline{warningpattern} = '.*' if
      $commandline{warningpattern} eq 'match_them_all';
  delete $commandline{warningpattern} if
      $commandline{warningpattern} eq 'match_never_ever';
}
if (my $cl = Nagios::CheckLogfiles->new({
      cfgfile => $commandline{config} ? $commandline{config} : undef,
      searches => [ 
          map {
            if (exists $commandline{type}) {
              # "eventlog" or "eventlog:eventlog=application,source=cdrom"
              my ($type, $details) = split(":", $commandline{type});
              $_->{type} = $type;
              if ($details) {
                $_->{$type} = {};
                foreach my $detail (split(",", $details)) {
                  my ($key, $value) = split("=", $detail);
                  $_->{$type}->{$key} = $value;
                }
              }
            }
            $_;
          }
          map { # ausputzen
              foreach my $key (keys %{$_}) { 
      	      delete $_->{$key} unless $_->{$key}}; $_;
          } ({
          tag => 
              $commandline{tag} ? $commandline{tag} : undef,
          logfile => 
              $commandline{logfile} ? $commandline{logfile} : undef,
          type => 
              $commandline{type} ? $commandline{type} : undef,
          rotation => 
              $commandline{rotation} ? $commandline{rotation} : undef,
          tivolipatterns =>
              $commandline{tivolipattern} ?
                  $commandline{tivolipattern} : undef,
          criticalpatterns =>
              $commandline{criticalpattern} ?
                  $commandline{criticalpattern} : undef,
          criticalexceptions =>
              $commandline{criticalexception} ?
                  $commandline{criticalexception} : undef,
          warningpatterns =>
              $commandline{warningpattern} ?
                  $commandline{warningpattern} : undef,
          warningexceptions =>
              $commandline{warningexception} ?
                  $commandline{warningexception} : undef,
          okpatterns =>
              $commandline{okpattern} ?
                  $commandline{okpattern} : undef,
          options => join(',', grep { $_ }
              $commandline{noprotocol} ? "noprotocol" : undef,
              $commandline{nocase} ? "nocase" : undef,
              $commandline{noperfdata} ? "noperfdata" : undef,
              $commandline{winwarncrit} ? "winwarncrit" : undef,
              $commandline{nologfilenocry} ? "nologfilenocry" : undef,
              $commandline{syslogserver} ? "syslogserver" : undef,
              $commandline{syslogclient} ? "syslogclient=".$commandline{syslogclient} : undef,
              $commandline{maxlength} ? "maxlength=".$commandline{maxlength} : undef,
              $commandline{lookback} ? "lookback=".$commandline{lookback} : undef,
              $commandline{context} ? "context=".$commandline{context} : undef,
              $commandline{criticalthreshold} ? "criticalthreshold=".$commandline{criticalthreshold} : undef,
              $commandline{warningthreshold} ? "warningthreshold=".$commandline{warningthreshold} : undef,
              $commandline{encoding} ? "encoding=".$commandline{encoding} : undef,
              defined $commandline{sticky} ? "sticky".($commandline{sticky} ? "=".$commandline{sticky} : "") : undef ),
          archivedir =>
              $commandline{archivedir} ?
                  $commandline{archivedir} : undef,
      })],
      selectedsearches => [split(/,/, $commandline{selectedsearches})],
      dynamictag => $commandline{tag} ? $commandline{tag} : undef,
      report => $commandline{report} ? $commandline{report} : undef,
      cmdlinemacros => $commandline{macro},
      seekfilesdir => $commandline{seekfilesdir} ? $commandline{seekfilesdir} : undef,
      protocolsdir => $commandline{protocolsdir} ? $commandline{protocolsdir} : undef,
      protocolsretention => $commandline{protocolsretention} ? $commandline{protocolsretention} : undef,
      reset => $commandline{reset} ? $commandline{reset} : undef,
  })) {
  $cl->{verbose} = $commandline{verbose} ? 1 : 0;
  $cl->{timeout} = $commandline{timeout} ? $commandline{timeout} : 60;
  if ($commandline{install}) {
    $cl->install_windows_service($commandline{service}, $commandline{config},
        $commandline{username}, $commandline{password});
  } elsif ($commandline{deinstall}) {
    $cl->deinstall_windows_service($commandline{service});
  } elsif ($commandline{daemon}) {
    $cl->run_as_daemon($commandline{daemon});
  } else {
    $cl->run();
  }
  printf "%s%s\n%s", $cl->{exitmessage},
      $cl->{perfdata} ? "|".$cl->{perfdata} : "",
      $cl->{long_exitmessage} ? $cl->{long_exitmessage}."\n" : "";
  exit $cl->{exitcode};
} else {
  printf "%s\n", $Nagios::CheckLogfiles::ExitMsg;
  exit $Nagios::CheckLogfiles::ExitCode;
}

