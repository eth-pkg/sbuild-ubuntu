#
# Chroot.pm: chroot library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
# Copyright © 2008      Simon McVittie <smcv@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

package Sbuild::Chroot;

use Sbuild qw(copy debug debug2);
use Sbuild::Base;
use Sbuild::ChrootInfo;
use Sbuild::ChrootSetup qw(basesetup);

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    my @filter;
    @filter = @{$self->get_conf('ENVIRONMENT_FILTER')}
	if (defined($self->get_conf('ENVIRONMENT_FILTER')));

    $self->set('Session ID', "");
    $self->set('Chroot ID', $chroot_id);
    $self->set('Defaults', {
	'COMMAND' => [],
	'INTCOMMAND' => [], # Private
	'EXPCOMMAND' => [], # Private
	'ENV' => {},
	'ENV_FILTER' => \@filter,
	'USER' => 'root',
	'CHROOT' => 1,
	'PRIORITY' => 0,
	'DIR' => '/',
	'SETSID' => 0,
	'STREAMIN' => undef,
	'STREAMOUT' => undef,
	'STREAMERR' => undef});

    if (!defined($self->get('Chroot ID'))) {
	return undef;
    }

    return $self;
}

sub _setup_options {
    my $self = shift;

    if ($self->get('Location') ne '/') {
	if (basesetup($self, $self->get('Config'))) {
	    print STDERR "Failed to set up chroot\n";
	    return 0;
	}
    }

    return 1;
}

sub get_option {
    my $self = shift;
    my $options = shift;
    my $option = shift;

    my $value = undef;
    $value = $self->get('Defaults')->{$option} if
	(defined($self->get('Defaults')) &&
	 defined($self->get('Defaults')->{$option}));
    $value = $options->{$option} if
	(defined($options) &&
	 exists($options->{$option}));

    return $value;
}

sub strip_chroot_path {
    my $self = shift;
    my $path = shift;

    my $location = $self->get('Location');
    $path =~ s/^\Q$location\E//;

    return $path;
}

sub log_command {
    my $self = shift;
    my $options = shift;

    my $priority = $options->{'PRIORITY'};

    if ((defined($priority) && $priority >= 1) || $self->get_conf('DEBUG')) {
	my $command;
	if ($self->get_conf('DEBUG')) {
	    $command = $options->{'EXPCOMMAND'};
	} else {
	    $command = $options->{'COMMAND'};
	}

	$self->log_info(join(" ", @$command), "\n");
    }
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub pipe_command_internal {
    my $self = shift;
    my $options = shift;

    my $pipetype = "-|";
    $pipetype = "|-" if (defined $options->{'PIPE'} &&
			 $options->{'PIPE'} eq 'out');

    my $pipe = undef;
    my $pid = open($pipe, $pipetype);
    if (!defined $pid) {
	warn "Cannot open pipe: $!\n";
    } elsif ($pid == 0) { # child
	if (!defined $options->{'PIPE'} ||
	    $options->{'PIPE'} ne 'out') { # redirect stdin
	    my $in = $self->get_option($options, 'STREAMIN');
	    if (defined($in) && $in && \*STDIN != $in) {
		open(STDIN, '<&', $in)
		    or warn "Can't redirect stdin\n";
	    }
	} else { # redirect stdout
	    my $out = $self->get_option($options, 'STREAMOUT');
	    if (defined($out) && $out && \*STDOUT != $out) {
		open(STDOUT, '>&', $out)
		    or warn "Can't redirect stdout\n";
	    }
	}
	# redirect stderr
	my $err = $self->get_option($options, 'STREAMERR');
	if (defined($err) && $err && \*STDERR != $err) {
	    open(STDERR, '>&', $err)
		or warn "Can't redirect stderr\n";
	}

	my $setsid = $self->get_option($options, 'SETSID');
	setsid() if defined($setsid) && $setsid;

	$self->exec_command($options);
    }

    debug2("Pipe (PID $pid, $pipe) created for: ",
	   join(" ", @{$options->{'COMMAND'}}),
	   "\n");

    $options->{'PID'} = $pid;

    return $pipe;
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub run_command_internal {
    my $self = shift;
    my $options = shift;

    my $pid = fork();

    if (!defined $pid) {
	warn "Cannot fork: $!\n";
    } elsif ($pid == 0) { # child

	# redirect stdout
	my $in = $self->get_option($options, 'STREAMIN');
	if (defined($in) && $in && \*STDIN != $in) {
	    open(STDIN, '<&', $in)
		or warn "Can't redirect stdin\n";
	}

	# redirect stdout
	my $out = $self->get_option($options, 'STREAMOUT');
	if (defined($out) && $out && \*STDOUT != $out) {
	    open(STDOUT, '>&', $out)
		or warn "Can't redirect stdout\n";
	}

	# redirect stderr
	my $err = $self->get_option($options, 'STREAMERR');
	if (defined($err) && $err && \*STDERR != $err) {
	    open(STDERR, '>&', $err)
		or warn "Can't redirect stderr\n";
	}

	my $setsid = $self->get_option($options, 'SETSID');
	setsid() if defined($setsid) && $setsid;

	$self->exec_command($options);
    }

    debug2("Pipe (PID $pid) created for: ",
	   join(" ", @{$options->{'COMMAND'}}),
	   "\n");

    waitpid($pid, 0);
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub run_command {
    my $self = shift;
    my $options = shift;

    $options->{'INTCOMMAND'} = copy($options->{'COMMAND'});
    $options->{'INTCOMMAND_STR'} = copy($options->{'COMMAND_STR'});

    return $self->run_command_internal($options);
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub pipe_command {
    my $self = shift;
    my $options = shift;

    $options->{'INTCOMMAND'} = copy($options->{'COMMAND'});
    $options->{'INTCOMMAND_STR'} = copy($options->{'COMMAND_STR'});

    return $self->pipe_command_internal($options);
}

sub exec_command {
    my $self = shift;
    my $options = shift;

    $self->get_command_internal($options);

    $self->log_command($options);

    my $command = $options->{'EXPCOMMAND'};

    my $program = $command->[0];
    $program = $options->{'PROGRAM'} if defined($options->{'PROGRAM'});

    my $chrootenv = $self->get('Defaults')->{'ENV'};
    foreach (keys %$chrootenv) {
	$ENV{$_} = $chrootenv->{$_};
    }

    my $commandenv = $options->{'ENV'};
    foreach (keys %$commandenv) {
	$ENV{$_} = $commandenv->{$_};
    }

    my @filter;
    my $chrootfilter = $self->get('Defaults')->{'ENV_FILTER'};
    push(@filter, @{$chrootfilter});

    my $commandfilter = $options->{'ENV_FILTER'};
    push(@filter, @{$commandfilter}) if defined($commandfilter);

    # Sanitise environment
    foreach my $var (keys %ENV) {
	my $match = 0;
	foreach my $regex (@filter) {
	    $match = 1 if
		$var =~ m/($regex)/;
	}
	delete $ENV{$var} if
	    $match == 0;
	if (!$match) {
	    debug2("Environment filter: Deleted $var\n");
	} else {
	    debug2("Environment filter: Kept $var\n");
	}
    }

    debug2("PROGRAM: $program\n");
    debug2("COMMAND: ", join(" ", @{$options->{'COMMAND'}}), "\n");
    debug2("COMMAND_STR: ", $options->{'COMMAND'} // 'UNDEFINED', "\n");
    debug2("INTCOMMAND: ", join(" ", @{$options->{'INTCOMMAND'}}), "\n");
    debug2("INTCOMMAND_STR: ", $options->{'INTCOMMAND_STR:'} // 'UNDEFINED', "\n");
    debug2("EXPCOMMAND: ", join(" ", @{$options->{'EXPCOMMAND'}}), "\n");

    debug2("Environment set:\n");
    foreach (sort keys %ENV) {
	debug2('  ' . $_ . '=' . ($ENV{$_} || '') . "\n");
    }

    debug("Running command: ", join(" ", @$command), "\n");
    exec { $program } @$command;
    die "Failed to exec: $command->[0]: $!";
}

sub lock_chroot {
    my $self = shift;
    my $new_job = shift;
    my $new_pid = shift;
    my $new_user = shift;

    my $lockfile = '/var/lock/sbuild';
    my $max_trys = $self->get_conf('MAX_LOCK_TRYS');
    my $lock_interval = $self->get_conf('LOCK_INTERVAL');

    # The following command in run /inside/ the chroot to create the lockfile.
    my $command = <<"EOF";

    use strict;
    use warnings;
    use POSIX;
    use FileHandle;

    my \$lockfile="$lockfile";
    my \$try = 0;

  repeat:
    if (!sysopen( F, \$lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
	if (\$! == EEXIST) {
	    # lock file exists, wait
	    goto repeat if !open( F, "<\$lockfile" );
	    my \$line = <F>;
	    my (\$job, \$pid, \$user);
	    close( F );
	    if (\$line !~ /^(\\S+)\\s+(\\S+)\\s+(\\S+)/) {
		print STDERR "Bad lock file contents (\$lockfile) -- still trying\\n";
	    } else {
		(\$job, \$pid, \$user) = (\$1, \$2, \$3);
		if (kill( 0, \$pid ) == 0 && \$! == ESRCH) {
		    # process no longer exists, remove stale lock
		    print STDERR "Removing stale lock file \$lockfile ".
			"(job \$job, pid \$pid, user \$user)\\n";
		    if (!unlink(\$lockfile)) {
			if (\$! != ENOENT) {
			    print STDERR "Cannot remove chroot lock file \$lockfile: \$!\\n";
			    exit 1;
			}
		    }
		}
	    }
	    ++\$try;
	    if (\$try > $max_trys) {
		print STDERR "Lockfile \$lockfile still present after " .
		    $max_trys * $lock_interval . " seconds -- giving up\\n";
		exit 1;
	    }
	    print STDERR "Another sbuild process (job \$job, pid \$pid by user \$user) is currently using the build chroot; waiting...\\n"
		if \$try == 1;
	    sleep $lock_interval;
	    goto repeat;
	} else {
	    print STDERR "Failed to create lock file \$lockfile: \$!\\n";
	    exit 1;
	}
    }

    F->print("$new_job $new_pid $new_user\\n");
    F->close();

    exit 0;
EOF

    $self->run_command(
	    { COMMAND => ['perl',
			  '-e',
			  $command],
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });

    if ($?) {
	return 0;
    }
    return 1;
}

sub unlock_chroot {
    my $self = shift;

    my $lockfile = '/var/lock/sbuild';

    # The following command in run /inside/ the chroot to remove the lockfile.
    my $command = <<"EOF";

    use strict;
    use warnings;
    use POSIX;

    my \$lockfile="$lockfile";
    if (!unlink(\$lockfile)) {
	print STDERR "Cannot remove chroot lock file \$lockfile: \$!\\n"
	    if \$! != ENOENT;
	exit 1;
    }
    exit 0;
EOF

    debug("Removing chroot lock file $lockfile\n");
    $self->run_command(
	    { COMMAND => ['perl',
			  '-e',
			  $command],
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });

    if ($?) {
	return 0;
    }
    return 1;
}

1;
