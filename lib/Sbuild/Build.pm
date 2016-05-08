#
# Build.pm: build library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2010 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Build;

use strict;
use warnings;

use English;
use POSIX;
use Errno qw(:POSIX);
use Fcntl;
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use FileHandle;
use File::Copy qw(); # copy is already exported from Sbuild, so don't export
		     # anything.
use Dpkg::Arch;
use Dpkg::Control;
use Dpkg::Index;
use Dpkg::Version;
use Dpkg::Deps qw(deps_concat deps_parse);
use Scalar::Util 'refaddr';

use MIME::Lite;
use Term::ANSIColor;

use Sbuild qw($devnull binNMU_version copy isin debug send_mail
              dsc_files dsc_pkgver);
use Sbuild::Base;
use Sbuild::ChrootInfoSchroot;
use Sbuild::ChrootInfoSudo;
use Sbuild::ChrootInfoADT;
use Sbuild::ChrootRoot;
use Sbuild::Sysconfig qw($version $release_date);
use Sbuild::Sysconfig;
use Sbuild::Resolver qw(get_resolver);
use Sbuild::Exception;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

our $saved_stdout = undef;
our $saved_stderr = undef;

sub new {
    my $class = shift;
    my $dsc = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('ABORT', undef);
    $self->set('Job', $dsc);
    $self->set('Build Dir', '');
    $self->set('Max Lock Trys', 120);
    $self->set('Lock Interval', 5);
    $self->set('Pkg Status', 'pending');
    $self->set('Pkg Status Trigger', undef);
    $self->set('Pkg Start Time', 0);
    $self->set('Pkg End Time', 0);
    $self->set('Pkg Fail Stage', 'init');
    $self->set('Build Start Time', 0);
    $self->set('Build End Time', 0);
    $self->set('Install Start Time', 0);
    $self->set('Install End Time', 0);
    $self->set('This Time', 0);
    $self->set('This Space', 0);
    $self->set('Sub Task', 'initialisation');
    $self->set('Host', Sbuild::ChrootRoot->new($self->get('Config')));
    # Host execution defaults
    my $host_defaults = $self->get('Host')->get('Defaults');
    $host_defaults->{'USER'} = $self->get_conf('USERNAME');
    $host_defaults->{'DIR'} = $self->get_conf('HOME');
    $host_defaults->{'STREAMIN'} = $devnull;
    $host_defaults->{'ENV'}->{'LC_ALL'} = 'POSIX';
    $host_defaults->{'ENV'}->{'SHELL'} = '/bin/sh';
    $host_defaults->{'ENV_FILTER'} = $self->get_conf('ENVIRONMENT_FILTER');
    # Note, this should never fail.  But, we should handle failure anyway.
    $self->get('Host')->begin_session();

    $self->set('Session', undef);
    $self->set('Dependency Resolver', undef);
    $self->set('Log File', undef);
    $self->set('Log Stream', undef);
    $self->set('Summary Stats', {});

    # DSC, package and version information:
    $self->set_dsc($dsc);

    # If the job name contains an underscore then it is either the filename of
    # a dsc or a pkgname_version string. In both cases we can already extract
    # the version number. Otherwise it is a bare source package name and the
    # version will initially be unknown.
    if ($dsc =~ m/_/) {
	$self->set_version($dsc);
    } else {
	$self->set('Package', $dsc);
    }

    return $self;
}

sub request_abort {
    my $self = shift;
    my $reason = shift;

    $self->log_error("ABORT: $reason (requesting cleanup and shutdown)\n");
    $self->set('ABORT', $reason);
}

sub check_abort {
    my $self = shift;

    if ($self->get('ABORT')) {
	Sbuild::Exception::Build->throw(error => "Aborting build: " .
					$self->get('ABORT'),
					failstage => "abort");
    }
}

sub set_dsc {
    my $self = shift;
    my $dsc = shift;

    debug("Setting DSC: $dsc\n");

    $self->set('DSC', $dsc);
    $self->set('Source Dir', dirname($dsc));
    $self->set('DSC Base', basename($dsc));

    debug("DSC = " . $self->get('DSC') . "\n");
    debug("Source Dir = " . $self->get('Source Dir') . "\n");
    debug("DSC Base = " . $self->get('DSC Base') . "\n");
}

sub set_version {
    my $self = shift;
    my $pkgv = shift;

    debug("Setting package version: $pkgv\n");

    my ($pkg, $version);
    if (-f $pkgv && -r $pkgv) {
	($pkg, $version) = dsc_pkgver($pkgv);
    } else {
	($pkg, $version) = split /_/, $pkgv;
    }
    my $pver = Dpkg::Version->new($version, check => 1);
    return if (!defined($pkg) || !defined($version) || !defined($pver));
    my ($o_version);
    $o_version = $pver->version();

    # Original version (no binNMU or other addition)
    my $oversion = $version;
    # Original version with stripped epoch
    my $osversion = $o_version;
    $osversion .= '-' . $pver->revision() unless $pver->{'no_revision'};

    # Add binNMU to version if needed.
    if ($self->get_conf('BIN_NMU') || $self->get_conf('APPEND_TO_VERSION')) {
	$version = binNMU_version($version, $self->get_conf('BIN_NMU_VERSION'),
	    $self->get_conf('APPEND_TO_VERSION'));
    }

    my $bver = Dpkg::Version->new($version, check => 1);
    return if (!defined($bver));
    my ($b_epoch, $b_version, $b_revision);
    $b_epoch = $bver->epoch();
    $b_epoch = "" if $bver->{'no_epoch'};
    $b_version = $bver->version();
    $b_revision = $bver->revision();
    $b_revision = "" if $bver->{'no_revision'};

    # Version with binNMU or other additions and stripped epoch
    my $sversion = $b_version;
    $sversion .= '-' . $b_revision if $b_revision ne '';

    $self->set('Package', $pkg);
    $self->set('Version', $version);
    $self->set('Package_Version', "${pkg}_$version");
    $self->set('Package_OVersion', "${pkg}_$oversion");
    $self->set('Package_OSVersion', "${pkg}_$osversion");
    $self->set('Package_SVersion', "${pkg}_$sversion");
    $self->set('OVersion', $oversion);
    $self->set('OSVersion', $osversion);
    $self->set('SVersion', $sversion);
    $self->set('VersionEpoch', $b_epoch);
    $self->set('VersionUpstream', $b_version);
    $self->set('VersionDebian', $b_revision);
    $self->set('DSC File', "${pkg}_${osversion}.dsc");
    $self->set('DSC Dir', "${pkg}-${b_version}");

    debug("Package = " . $self->get('Package') . "\n");
    debug("Version = " . $self->get('Version') . "\n");
    debug("Package_Version = " . $self->get('Package_Version') . "\n");
    debug("Package_OVersion = " . $self->get('Package_OVersion') . "\n");
    debug("Package_OSVersion = " . $self->get('Package_OSVersion') . "\n");
    debug("Package_SVersion = " . $self->get('Package_SVersion') . "\n");
    debug("OVersion = " . $self->get('OVersion') . "\n");
    debug("OSVersion = " . $self->get('OSVersion') . "\n");
    debug("SVersion = " . $self->get('SVersion') . "\n");
    debug("VersionEpoch = " . $self->get('VersionEpoch') . "\n");
    debug("VersionUpstream = " . $self->get('VersionUpstream') . "\n");
    debug("VersionDebian = " . $self->get('VersionDebian') . "\n");
    debug("DSC File = " . $self->get('DSC File') . "\n");
    debug("DSC Dir = " . $self->get('DSC Dir') . "\n");
}

sub set_status {
    my $self = shift;
    my $status = shift;

    $self->set('Pkg Status', $status);
    if (defined($self->get('Pkg Status Trigger'))) {
	$self->get('Pkg Status Trigger')->($self, $status);
    }
}

sub get_status {
    my $self = shift;

    return $self->get('Pkg Status');
}

# This function is the main entry point into the package build.  It
# provides a top-level exception handler and does the initial setup
# including initiating logging and creating host chroot.  The nested
# run_ functions it calls are separate in order to permit running
# cleanup tasks in a strict order.
sub run {
    my $self = shift;

    eval {
	$self->check_abort();

	$self->set_status('building');

	$self->set('Pkg Start Time', time);
	$self->set('Pkg End Time', $self->get('Pkg Start Time'));

	# Acquire the architectures we're building for and on.
	$self->set('Host Arch', $self->get_conf('HOST_ARCH'));
	$self->set('Build Arch', $self->get_conf('BUILD_ARCH'));
	$self->set('Build Profiles', $self->get_conf('BUILD_PROFILES'));

	if (!$self->get_conf('BUILD_ARCH_ANY') &&
	    !$self->get_conf('BUILD_ARCH_ALL') &&
	    !$self->get_conf('BUILD_SOURCE')) {
	    Sbuild::Exception::Build->throw(error => "Neither architecture specific nor architecture independent or source package specified to be built.",
					    failstage => "init");
	}

	my $dist = $self->get_conf('DISTRIBUTION');
	if (!defined($dist) || !$dist) {
	    Sbuild::Exception::Build->throw(error => "No distribution defined",
					    failstage => "init");
	}

	# TODO: Get package name from build object
	if (!$self->open_build_log()) {
	    Sbuild::Exception::Build->throw(error => "Failed to open build log",
					    failstage => "init");
	}

	# Set a chroot to run commands in host
	my $host = $self->get('Host');

	# Host execution defaults (set streams)
	my $host_defaults = $host->get('Defaults');
	$host_defaults->{'STREAMIN'} = $devnull;
	$host_defaults->{'STREAMOUT'} = $self->get('Log Stream');
	$host_defaults->{'STREAMERR'} = $self->get('Log Stream');

	$self->check_abort();
	$self->run_chroot();
    };

    debug("Error run(): $@") if $@;

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	if ($e->status) {
	    $self->set_status($e->status);
	} else {
	    $self->set_status("failed");
	}
	$self->set('Pkg Fail Stage', $e->failstage);
	$e->rethrow();
    }
}

# Pack up source if needed and then run the main chroot session.
# Close log during return/failure.
sub run_chroot {
    my $self = shift;

    eval {
	$self->check_abort();
	$self->run_chroot_session();
    };

    debug("Error run_chroot(): $@") if $@;

    # Log exception info and set status and fail stage prior to
    # closing build log.
    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$self->log_error("$e\n");
	$self->log_info($e->info."\n")
	    if ($e->info);
	if ($e->status) {
	    $self->set_status($e->status);
	} else {
	    $self->set_status("failed");
	}
	$self->set('Pkg Fail Stage', $e->failstage);
    }

    $self->close_build_log();

    if ($e) {
	$e->rethrow();
    }
}

# Create main chroot session and package resolver.  Creates a lock in
# the chroot to prevent concurrent chroot usage (only important for
# non-snapshot chroots).  Ends chroot session on return/failure.
sub run_chroot_session {
    my $self=shift;

    eval {
	$self->check_abort();
	my $chroot_info;
	if ($self->get_conf('CHROOT_MODE') eq 'schroot') {
	    $chroot_info = Sbuild::ChrootInfoSchroot->new($self->get('Config'));
	} elsif ($self->get_conf('CHROOT_MODE') eq 'adt') {
	    $chroot_info = Sbuild::ChrootInfoADT->new($self->get('Config'));
	} else {
	    $chroot_info = Sbuild::ChrootInfoSudo->new($self->get('Config'));
	}

	my $host = $self->get('Host');

	my $session = $chroot_info->create('chroot',
					   $self->get_conf('DISTRIBUTION'),
					   $self->get_conf('CHROOT'),
					   $self->get_conf('BUILD_ARCH'));
        if (!defined $session) {
	    Sbuild::Exception::Build->throw(error => "Error creating chroot",
					    failstage => "create-session");
        }

	$self->check_abort();
	if (!$session->begin_session()) {
	    Sbuild::Exception::Build->throw(error => "Error creating chroot session: skipping " .
					    $self->get('Package'),
					    failstage => "create-session");
	}

	$self->set('Session', $session);

	$self->check_abort();
	my $chroot_arch =  $self->chroot_arch();
	if ($self->get_conf('BUILD_ARCH') ne $chroot_arch) {
	    Sbuild::Exception::Build->throw(
		error => "Requested build architecture (" .
		$self->get_conf('BUILD_ARCH') .
		") and chroot architecture (" . $chroot_arch .
		") do not match.  Skipping build.",
		info => "Please specify the correct architecture with --build, or use a chroot of the correct architecture",
		failstage => "create-session");
	}

	if (defined($self->get_conf('BUILD_PATH')) && $self->get_conf('BUILD_PATH')) {
	    my $build_path = $self->get_conf('BUILD_PATH');
	    $self->set('Build Dir', $build_path);
	    if (!($session->test_directory($build_path))) {
		if (!$session->mkdir($build_path, { PARENTS => 1})) {
		    Sbuild::Exception::Build->throw(
			error => "Buildpath: " . $build_path . " cannot be created",
			failstage => "create-session");
		}
	    } else {
		my $isempty = <<END;
if (opendir my \$dfh, "$build_path") {
    while (defined(my \$file=readdir \$dfh)) {
	next if \$file eq "." or \$file eq "..";
	closedir \$dfh;
	exit 1
    }
    closedir \$dfh;
    exit 0
}
exit 2
END
		$session->run_command({
			COMMAND => ['perl', '-e', $isempty],
			USER => 'root',
			DIR => '/'
		    });
		if ($? == 1) {
		    Sbuild::Exception::Build->throw(
			error => "Buildpath: " . $build_path . " is not empty",
			failstage => "create-session");
		}
		elsif ($? == 2) {
		    Sbuild::Exception::Build->throw(
			error => "Buildpath: " . $build_path . " cannot be read. Insufficient permissions?",
			failstage => "create-session");
		}
	    }
	} else {
		# we run mktemp within the chroot instead of using File::Temp::tempdir because the user
		# running sbuild might not have permissions creating a directory in /build. This happens
		# when the chroot was extracted in a different user namespace than the outer user
		$self->check_abort();
		my $tmpdir = $session->mktemp({
			TEMPLATE => "/build/" . $self->get('Package') . '-XXXXXX',
			DIRECTORY => 1});
		if (!$tmpdir) {
			$self->log_error("unable to mktemp\n");
			Sbuild::Exception::Build->throw(error => "unable to mktemp",
				failstage => "create-build-dir");
		}
		$self->check_abort();
		$self->set('Build Dir', $tmpdir);
	}


	# Run pre build external commands
	$self->check_abort();
	if(!$self->run_external_commands("pre-build-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute pre-build-commands",
		failstage => "run-pre-build-commands");
	}

	# Log colouring
	$self->build_log_colour('red', '^E: ');
	$self->build_log_colour('yellow', '^W: ');
	$self->build_log_colour('green', '^I: ');
	$self->build_log_colour('red', '^Status:');
	$self->build_log_colour('green', '^Status: successful$');
	$self->build_log_colour('yellow', '^Keeping session: ');
	$self->build_log_colour('red', '^Lintian:');
	$self->build_log_colour('green', '^Lintian: pass$');

	# Log filtering
	my $filter;
	$filter = $session->get('Location');
	$filter =~ s;^/;;;
	$self->build_log_filter($filter , 'CHROOT');

	# Need tempdir to be writable and readable by sbuild group.
	$self->check_abort();
	if (!$session->chown($self->get('Build Dir'), $self->get_conf('BUILD_USER'), 'sbuild')) {
	    Sbuild::Exception::Build->throw(error => "Failed to set sbuild group ownership on chroot build dir",
					    failstage => "create-build-dir");
	}
	$self->check_abort();
	if (!$session->chmod($self->get('Build Dir'), "ug=rwx,o=,a-s")) {
	    Sbuild::Exception::Build->throw(error => "Failed to set sbuild group ownership on chroot build dir",
					    failstage => "create-build-dir");
	}

	$self->check_abort();
	# Needed so chroot commands log to build log
	$session->set('Log Stream', $self->get('Log Stream'));
	$host->set('Log Stream', $self->get('Log Stream'));

	# Chroot execution defaults
	my $chroot_defaults = $session->get('Defaults');
	$chroot_defaults->{'DIR'} = $self->get('Build Dir');
	$chroot_defaults->{'STREAMIN'} = $devnull;
	$chroot_defaults->{'STREAMOUT'} = $self->get('Log Stream');
	$chroot_defaults->{'STREAMERR'} = $self->get('Log Stream');
	$chroot_defaults->{'ENV'}->{'LC_ALL'} = 'POSIX';
	$chroot_defaults->{'ENV'}->{'SHELL'} = '/bin/sh';
	$chroot_defaults->{'ENV'}->{'HOME'} = '/sbuild-nonexistent';
	$chroot_defaults->{'ENV_FILTER'} = $self->get_conf('ENVIRONMENT_FILTER');

	my $resolver = get_resolver($self->get('Config'), $session, $host);
	$resolver->set('Log Stream', $self->get('Log Stream'));
	$resolver->set('Arch', $self->get_conf('ARCH'));
	$resolver->set('Host Arch', $self->get_conf('HOST_ARCH'));
	$resolver->set('Build Arch', $self->get_conf('BUILD_ARCH'));
	$resolver->set('Build Profiles', $self->get_conf('BUILD_PROFILES'));
	$resolver->set('Build Dir', $self->get('Build Dir'));
	$self->set('Dependency Resolver', $resolver);

	# Lock chroot so it won't be tampered with during the build.
	$self->check_abort();
	my $jobname;
	# the version might not yet be known if the user only passed a package
	# name without a version to sbuild
	if ($self->get('Package_SVersion')) {
	    $jobname = $self->get('Package_SVersion');
	} else {
	    $jobname = $self->get('Package');
	}
	if (!$session->lock_chroot($jobname, $$, $self->get_conf('USERNAME'))) {
	    Sbuild::Exception::Build->throw(error => "Error locking chroot session: skipping " .
					    $self->get('Package'),
					    failstage => "lock-session");
	}

	$self->check_abort();
	$self->run_chroot_session_locked();
    };

    debug("Error run_chroot_session(): $@") if $@;

    # End chroot session
    my $session = $self->get('Session');
    if (defined $session) {
	    my $end_session =
		    ($self->get_conf('PURGE_SESSION') eq 'always' ||
		     ($self->get_conf('PURGE_SESSION') eq 'successful' &&
		      $self->get_status() eq 'successful')) ? 1 : 0;
	    if ($end_session) {
		    $session->end_session();
	    } else {
		    $self->log("Keeping session: " . $session->get('Session ID') . "\n");
	    }
	    $session = undef;
    }
    $self->set('Session', $session);

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$e->rethrow();
    }
}

# Run tasks in a *locked* chroot.  Update and upgrade packages.
# Unlocks chroot on return/failure.
sub run_chroot_session_locked {
    my $self = shift;

    eval {
	my $session = $self->get('Session');
	my $resolver = $self->get('Dependency Resolver');

	# Run specified chroot setup commands
	$self->check_abort();
	if(!$self->run_external_commands("chroot-setup-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute chroot-setup-commands",
		failstage => "run-chroot-setup-commands");
	}

	$self->check_abort();


	$self->check_abort();
	if (!$resolver->setup()) {
		Sbuild::Exception::Build->throw(error => "resolver setup failed",
						failstage => "resolver setup");
	}

	$self->check_abort();
	$self->run_chroot_update();

	$self->check_abort();
	$self->run_fetch_install_packages();
    };

    debug("Error run_chroot_session_locked(): $@") if $@;

    my $session = $self->get('Session');
    my $resolver = $self->get('Dependency Resolver');

    $resolver->cleanup();
    # Unlock chroot now it's cleaned up and ready for other users.
    $session->unlock_chroot();

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$e->rethrow();
    }
}

sub run_chroot_update {
    my $self = shift;
    my $resolver = $self->get('Dependency Resolver');

    eval {
	if ($self->get_conf('APT_CLEAN') || $self->get_conf('APT_UPDATE') ||
	    $self->get_conf('APT_DISTUPGRADE') || $self->get_conf('APT_UPGRADE')) {
	    $self->log_subsection('Update chroot');
	}

	# Clean APT cache.
	$self->check_abort();
	if ($self->get_conf('APT_CLEAN')) {
	    if ($resolver->clean()) {
		# Since apt-clean was requested specifically, fail on
		# error when not in buildd mode.
		$self->log_error("apt-get clean failed\n");
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    Sbuild::Exception::Build->throw(error => "apt-get clean failed",
						    failstage => "apt-get-clean");
		}
	    }
	}

	# Update APT cache.
	$self->check_abort();
	if ($self->get_conf('APT_UPDATE')) {
	    if ($resolver->update()) {
		# Since apt-update was requested specifically, fail on
		# error when not in buildd mode.
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    Sbuild::Exception::Build->throw(error => "apt-get update failed",
						    failstage => "apt-get-update");
		}
	    }
	} else {
	    # If it was requested not to do an apt update, the build and host
	    # architecture must already be part of the chroot. If they are not
	    # and thus added during the sbuild run, issue a warning because
	    # then the package build dependencies will likely fail to be
	    # installable.
	    #
	    # The logic which checks which architectures are needed is in
	    # ResolverBase.pm, so we just check whether any architectures
	    # where added with 'dpkg --add-architecture' because if any were
	    # added an update is most likely needed.
	    if (keys %{$resolver->get('Added Foreign Arches')}) {
		$self->log_warning("Additional architectures were added but apt update was disabled. Build dependencies might not be satisfiable.\n");
	    }
	}

	# Upgrade using APT.
	$self->check_abort();
	if ($self->get_conf('APT_DISTUPGRADE')) {
	    if ($resolver->distupgrade()) {
		# Since apt-distupgrade was requested specifically, fail on
		# error when not in buildd mode.
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    Sbuild::Exception::Build->throw(error => "apt-get dist-upgrade failed",
						    failstage => "apt-get-dist-upgrade");
		}
	    }
	} elsif ($self->get_conf('APT_UPGRADE')) {
	    if ($resolver->upgrade()) {
		# Since apt-upgrade was requested specifically, fail on
		# error when not in buildd mode.
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    Sbuild::Exception::Build->throw(error => "apt-get upgrade failed",
						    failstage => "apt-get-upgrade");
		}
	    }
	}
    };

    debug("Error run_chroot_update(): $@") if $@;

    my $e = Exception::Class->caught('Sbuild::Exception::Build');
    if ($e) {
	$self->run_external_commands("chroot-update-failed-commands");
	$e->rethrow();
    }
}

# Fetch sources, run setup, fetch and install core and package build
# deps, then run build.  Cleans up build directory and uninstalls
# build depends on return/failure.
sub run_fetch_install_packages {
    my $self = shift;

    $self->check_abort();
    eval {
	my $session = $self->get('Session');
	my $resolver = $self->get('Dependency Resolver');

	$self->check_abort();
	if (!$self->fetch_source_files()) {
	    Sbuild::Exception::Build->throw(error => "Failed to fetch source files",
					    failstage => "fetch-src");
	}

	# Display message about chroot setup script option use being deprecated
	if ($self->get_conf('CHROOT_SETUP_SCRIPT')) {
	    my $msg = "setup-hook option is deprecated. It has been superceded by ";
	    $msg .= "the chroot-setup-commands feature. setup-hook script will be ";
	    $msg .= "run via chroot-setup-commands.\n";
	    $self->log_warning($msg);
	}

	if ($self->get('Host Arch') ne $self->get('Build Arch')) {
	    $self->log_subsection("Install crossbuild-essential");
	} else {
	    $self->log_subsection("Install build-essential");
	}

	$self->check_abort();
	$self->set('Install Start Time', time);
	$self->set('Install End Time', $self->get('Install Start Time'));
	my @coredeps = @{$self->get_conf('CORE_DEPENDS')};
	if ($self->get('Host Arch') ne $self->get('Build Arch')) {
	    my $crosscoredeps = $self->get_conf('CROSSBUILD_CORE_DEPENDS');
	    if (defined($crosscoredeps->{$self->get('Host Arch')})) {
	        push(@coredeps, @{$crosscoredeps->{$self->get('Host Arch')}});
	    } else {
		push(@coredeps, 'crossbuild-essential-' . $self->get('Host Arch') . ':native');
            }
	}
	$resolver->add_dependencies('CORE', join(", ", @coredeps) , "", "", "", "", "");

	if (!$resolver->install_core_deps('core', 'CORE')) {
	    Sbuild::Exception::Build->throw(error => "Core build dependencies not satisfied; skipping",
					    failstage => "install-deps");
	}

	# the architecture check has to be done *after* build-essential is
	# installed because as part of the architecture check a perl script is
	# run inside the chroot which requires the Dpkg::Arch module which is
	# in libdpkg-perl which might not exist in the chroot but will get
	# installed by the build-essential package
	if(!$self->check_architectures()) {
	    Sbuild::Exception::Build->throw(error => "Architecture check failed",
					    failstage => "check-architecture");
	}

	my $snapshot = "";
	$snapshot = "gcc-snapshot" if ($self->get_conf('GCC_SNAPSHOT'));
	$resolver->add_dependencies('GCC_SNAPSHOT', $snapshot , "", "", "", "", "");

	# Add additional build dependencies specified on the command-line.
	# TODO: Split dependencies into an array from the start to save
	# lots of joining.
	$resolver->add_dependencies('MANUAL',
				    join(", ", @{$self->get_conf('MANUAL_DEPENDS')}),
				    join(", ", @{$self->get_conf('MANUAL_DEPENDS_ARCH')}),
				    join(", ", @{$self->get_conf('MANUAL_DEPENDS_INDEP')}),
				    join(", ", @{$self->get_conf('MANUAL_CONFLICTS')}),
				    join(", ", @{$self->get_conf('MANUAL_CONFLICTS_ARCH')}),
				    join(", ", @{$self->get_conf('MANUAL_CONFLICTS_INDEP')}));

	$resolver->add_dependencies($self->get('Package'),
				    $self->get('Build Depends'),
				    $self->get('Build Depends Arch'),
				    $self->get('Build Depends Indep'),
				    $self->get('Build Conflicts'),
				    $self->get('Build Conflicts Arch'),
				    $self->get('Build Conflicts Indep'));

	my @build_deps;
	if ($self->get('Host Arch') eq $self->get('Build Arch')) {
	    @build_deps = ('GCC_SNAPSHOT', 'MANUAL',
			   $self->get('Package'));
	} else {
	    $self->check_abort();
	    if (!$resolver->install_core_deps('essential',
					      'GCC_SNAPSHOT')) {
		Sbuild::Exception::Build->throw(error => "Essential dependencies not satisfied; skipping",
						failstage => "install-essential");
	    }
	    @build_deps = ('MANUAL', $self->get('Package'));
	}

	$self->log_subsection("Install package build dependencies");

	$self->check_abort();
	if (!$resolver->install_main_deps($self->get('Package'),
					  @build_deps)) {
	    Sbuild::Exception::Build->throw(error => "Package build dependencies not satisfied; skipping",
					    failstage => "install-deps");
	}
	$self->set('Install End Time', time);

	$self->check_abort();
	$resolver->dump_build_environment();

	$self->check_abort();
	if ($self->build()) {
	    $self->set_status('successful');
	} else {
	    $self->set('Pkg Fail Stage', "build");
	    $self->set_status('failed');
	}

	# Run specified chroot cleanup commands
	$self->check_abort();
	if (!$self->run_external_commands("chroot-cleanup-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute chroot-cleanup-commands",
		failstage => "run-chroot-cleanup-commands");
	}

	if ($self->get('Pkg Status') eq "successful") {
	    $self->log_subsection("Post Build");

	    # Run piuparts.
	    $self->check_abort();
	    $self->run_piuparts();

	    # Run post build external commands
	    $self->check_abort();
	    if(!$self->run_external_commands("post-build-commands")) {
		Sbuild::Exception::Build->throw(error => "Failed to execute post-build-commands",
		    failstage => "run-post-build-commands");
	    }

	}
    };

    debug("Error run_fetch_install_packages(): $@") if $@;

    # I catch the exception here and trigger the hook, if needed. Normally I'd
    # do this at the end of the function, but I want the hook to fire before we
    # clean up the environment. I re-throw the exception at the end, as usual
    my $e = Exception::Class->caught('Sbuild::Exception::Build');
    if ( defined $self->get('Pkg Fail Stage') &&
         $self->get('Pkg Fail Stage') eq 'build' ) {
	if(!$self->run_external_commands("build-failed-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute build-failed-commands",
		failstage => "run-build-failed-commands");
	}
    } elsif($e) {

	if(!$self->run_external_commands("build-deps-failed-commands")) {
	    Sbuild::Exception::Build->throw(error => "Failed to execute build-deps-failed-commands",
		failstage => "run-build-deps-failed-commands");
	}
    }




    $self->log_subsection("Cleanup");
    my $session = $self->get('Session');
    my $resolver = $self->get('Dependency Resolver');

    my $purge_build_directory =
	($self->get_conf('PURGE_BUILD_DIRECTORY') eq 'always' ||
	 ($self->get_conf('PURGE_BUILD_DIRECTORY') eq 'successful' &&
	  $self->get_status() eq 'successful')) ? 1 : 0;
    my $purge_build_deps =
	($self->get_conf('PURGE_BUILD_DEPS') eq 'always' ||
	 ($self->get_conf('PURGE_BUILD_DEPS') eq 'successful' &&
	  $self->get_status() eq 'successful')) ? 1 : 0;
    my $is_cloned_session = (defined ($session->get('Session Purged')) &&
			     $session->get('Session Purged') == 1) ? 1 : 0;

    if ($purge_build_directory) {
	# Purge package build directory
	$self->log("Purging " . $self->get('Build Dir') . "\n");
	if (!$self->get('Session')->unlink($self->get('Build Dir'), { RECURSIVE => 1 })) {
		$self->log_error("unable to remove build directory\n");
	}
    }

    # Purge non-cloned session
    if ($is_cloned_session) {
	$self->log("Not cleaning session: cloned chroot in use\n");
    } else {
	if ($purge_build_deps) {
	    # Removing dependencies
	    $resolver->uninstall_deps();
	} else {
	    $self->log("Not removing build depends: as requested\n");
	}
    }


    # re-throw the previously-caught exception
    if ($e) {
	$e->rethrow();
    }
}

sub copy_to_chroot {
    my $self = shift;
    my $source = shift;
    my $chrootdest = shift;

    my $session = $self->get('Session');

    $self->check_abort();
    if(!$session->copy_to_chroot($source, $chrootdest)) {
	$self->log_error("E: Failed to copy $source to $chrootdest\n");
	return 0;
    }

    if (!$session->chown($chrootdest, $self->get_conf('BUILD_USER'), 'sbuild')) {
	$self->log_error("E: Failed to set sbuild group ownership on $chrootdest\n");
	return 0;
    }
    if (!$session->chmod($chrootdest, "ug=rw,o=r,a-s")) {
	$self->log_error("E: Failed to set 0644 permissions on $chrootdest\n");
	return 0;
    }

    return 1;
}
sub fetch_source_files {
    my $self = shift;

    my $build_dir = $self->get('Build Dir');
    my $host_arch = $self->get('Host Arch');
    my $resolver = $self->get('Dependency Resolver');

    my ($dscarchs, $dscpkg, $dscver, $dsc);

    my $build_depends = "";
    my $build_depends_arch = "";
    my $build_depends_indep = "";
    my $build_conflicts = "";
    my $build_conflicts_arch = "";
    my $build_conflicts_indep = "";
    local( *F );

    $self->log_subsection("Fetch source files");

    $self->check_abort();
    if ($self->get('DSC Base') =~ m/\.dsc$/) {
	my $dir = $self->get('Source Dir');

	# Work with a .dsc file.
	my $file = $self->get('DSC');
	$dsc = $self->get('DSC File');
	if (! -f $file || ! -r $file) {
	    $self->log_error("Could not find $file\n");
	    return 0;
	}
	my @cwd_files = dsc_files($file);

	# Copy the local source files into the build directory.
	$self->log_subsubsection("Local sources");
	$self->log("$file exists in $dir; copying to chroot\n");
	if (! $self->copy_to_chroot("$file", "$build_dir/$dsc")) {
	    return 0;
	}
	foreach (@cwd_files) {
	    if (! $self->copy_to_chroot("$dir/$_", "$build_dir/$_")) {
		return 0;
	    }
	}
    } else {
	my $pkg = $self->get('DSC');
	my $ver;

	if ($pkg =~ m/_/) {
	    ($pkg, $ver) = split /_/, $pkg;
	}

	# Use apt to download the source files
	$self->log_subsubsection("Check APT");
	my %entries = ();
	$self->log("Checking available source versions...\n");

	my $pipe = $self->get('Dependency Resolver')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_CACHE'),
			  '-q', '--only-source', 'showsrc', $pkg],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0,
	      DIR => '/'});
	if (!$pipe) {
	    $self->log_error("Can't open pipe to ".$self->get_conf('APT_CACHE').": $!\n");
	    return 0;
	}

	my $key_func = sub {
	    return $_[0]->{Package} . '_' . $_[0]->{Version};
	};

	my $index = Dpkg::Index->new(get_key_func=>$key_func);

	if (!$index->parse($pipe, 'apt-cache showsrc')) {
	    $self->log_error("Cannot parse output of apt-cache showsrc: $!\n");
	    return 0;
	}

	close($pipe);

	if ($?) {
	    $self->log_error($self->get_conf('APT_CACHE') . " exit status $?: $!\n");
	    return 0;
	}

	my $highestversion;
	my $highestdsc;

	foreach my $key ($index->get_keys()) {
	    my $cdata = $index->get_by_key($key);
	    my $pkgname = $cdata->{"Package"};
	    if (not defined($pkgname)) {
		$self->log_warning("apt-cache output without Package field\n");
		next;
	    }
	    if ($pkg ne $pkgname) {
		$self->log_warning("apt-cache output for different package\n");
		next;
	    }
	    my $pkgversion = $cdata->{"Version"};
	    if (not defined($pkgversion)) {
		$self->log_warning("apt-cache output without Version field\n");
		next;
	    }
	    if (defined($ver) and $ver ne $pkgversion) {
		next;
	    }
	    my $checksums = Dpkg::Checksums->new();
	    $checksums->add_from_control($cdata, use_files_for_md5 => 1);
	    my @files = grep {/\.dsc$/} $checksums->get_files();
	    if (scalar @files != 1) {
		$self->log_warning("apt-cache output with more than one .dsc\n");
		next;
	    }
	    if (!defined $highestdsc) {
		$highestdsc = $files[0];
		$highestversion = $pkgversion;
	    } else {
		if (version_compare($highestversion, $pkgversion) < 0) {
		    $highestdsc = $files[0];
		    $highestversion = $pkgversion;
		}
	    }
	}

	if (!defined $highestdsc) {
	    $self->log_error($self->get_conf('APT_CACHE') .
		" returned no information about $pkg source\n");
	    $self->log_error("Are there any deb-src lines in your /etc/apt/sources.list?\n");
	    return 0;
	}

	$self->set_dsc($highestdsc);
	$dsc = $highestdsc;

	$self->log_subsubsection("Download source files with APT");

	my $pipe2 = $self->get('Dependency Resolver')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_GET'), '--only-source', '-q', '-d', 'source', "$pkg=$highestversion"],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0}) || return 0;

	while(<$pipe2>) {
	    $self->log($_);
	}
	close($pipe2);
	if ($?) {
	    $self->log_error($self->get_conf('APT_GET') . " for sources failed\n");
	    return 0;
	}
    }

    my $pipe = $self->get('Session')->get_read_file_handle("$build_dir/$dsc");
    if (!$pipe) {
	$self->log_error("unable to open pipe\n");
	return 0;
    }

    my $pdsc = Dpkg::Control->new(type => CTRL_PKG_SRC);
    $pdsc->set_options(allow_pgp => 1);
    if (!$pdsc->parse($pipe, "$build_dir/$dsc")) {
	$self->log_error("Error parsing $build_dir/$dsc");
	return 0;
    }

    close($pipe);

    $build_depends = $pdsc->{'Build-Depends'};
    $build_depends_arch = $pdsc->{'Build-Depends-Arch'};
    $build_depends_indep = $pdsc->{'Build-Depends-Indep'};
    $build_conflicts = $pdsc->{'Build-Conflicts'};
    $build_conflicts_arch = $pdsc->{'Build-Conflicts-Arch'};
    $build_conflicts_indep = $pdsc->{'Build-Conflicts-Indep'};
    $dscarchs = $pdsc->{'Architecture'};
    $dscpkg = $pdsc->{'Source'};
    $dscver = $pdsc->{'Version'};

    $self->set_version("${dscpkg}_${dscver}");

    $build_depends =~ s/\n\s+/ /g if defined $build_depends;
    $build_depends_arch =~ s/\n\s+/ /g if defined $build_depends_arch;
    $build_depends_indep =~ s/\n\s+/ /g if defined $build_depends_indep;
    $build_conflicts =~ s/\n\s+/ /g if defined $build_conflicts;
    $build_conflicts_arch =~ s/\n\s+/ /g if defined $build_conflicts_arch;
    $build_conflicts_indep =~ s/\n\s+/ /g if defined $build_conflicts_indep;

    $self->set('Build Depends', $build_depends);
    $self->set('Build Depends Arch', $build_depends_arch);
    $self->set('Build Depends Indep', $build_depends_indep);
    $self->set('Build Conflicts', $build_conflicts);
    $self->set('Build Conflicts Arch', $build_conflicts_arch);
    $self->set('Build Conflicts Indep', $build_conflicts_indep);

    $self->set('Dsc Architectures', $dscarchs);

    # we set up the following filters this late because the user might only
    # have specified a source package name to build without a version in which
    # case we only get to know the final build directory now
    my $filter;
    $filter = $self->get('Build Dir') . '/' . $self->get('DSC Dir');
    $filter =~ s;^/;;;
    $self->build_log_filter($filter, 'PKGBUILDDIR');
    $filter = $self->get('Build Dir');
    $filter =~ s;^/;;;
    $self->build_log_filter($filter, 'BUILDDIR');

    return 1;
}

sub check_architectures {
    my $self = shift;
    my $resolver = $self->get('Dependency Resolver');
    my $dscarchs = $self->get('Dsc Architectures');
    my $host_arch = $self->get('Host Arch');

    $self->log_subsection("Check architectures");
    # Check for cross-arch dependencies
    # parse $build_depends* for explicit :arch and add the foreign arches, as needed
    sub get_explicit_arches
    {
        my $visited_deps = pop;
        my @deps = @_;

        my %set;
        for my $dep (@deps)
        {
            # Break any recursion in the deps data structure (is this overkill?)
            next if !defined $dep;
            my $id = ref($dep) ? refaddr($dep) : "str:$dep";
            next if $visited_deps->{$id};
            $visited_deps->{$id} = 1;

            if ( exists( $dep->{archqual} ) )
            {
                if ( $dep->{archqual} )
                {
                    $set{$dep->{archqual}} = 1;
                }
            }
            else
            {
                for my $key (get_explicit_arches($dep->get_deps,
                                                 $visited_deps)) {
                    $set{$key} = 1;
                }
            }
        }

        return keys %set;
    }

    # we don't need to look at build conflicts here because conflicting with a
    # package of an explicit architecture does not mean that we need to enable
    # that architecture in the chroot
    my $build_depends_concat =
      deps_concat( grep {defined $_} ($self->get('Build Depends'),
                                      $self->get('Build Depends Arch'),
                                      $self->get('Build Depends Indep')));
    my $merged_depends = deps_parse( $build_depends_concat,
		reduce_arch => 1,
		host_arch => $self->get('Host Arch'),
		build_arch => $self->get('Build Arch'),
		build_dep => 1,
		reduce_profiles => 1,
		build_profiles => [ split / /, $self->get('Build Profiles') ]);
    if( !defined $merged_depends ) {
        my $msg = "Error! deps_parse() couldn't parse the Build-Depends '$build_depends_concat'";
        $self->log_error("$msg\n");
        return 0;
    }

    my @explicit_arches = get_explicit_arches($merged_depends, {});
    my @foreign_arches = grep {$_ !~ /any|all|native/} @explicit_arches;
    my $added_any_new;
    for my $foreign_arch(@foreign_arches)
    {
        $resolver->add_foreign_architecture($foreign_arch);
        $added_any_new = 1;
    }

    my @keylist=keys %{$resolver->get('Initial Foreign Arches')};
    $self->log('Initial Foreign Architectures: ' . join ' ', @keylist, "\n")
      if @keylist;
    $self->log('Foreign Architectures in build-deps: '. join ' ', @foreign_arches, "\n\n")
      if @foreign_arches;

    $self->run_chroot_update() if $added_any_new;


    # Check package arch makes sense to build
    if (!$dscarchs) {
	$self->log_warning("dsc has no Architecture: field -- skipping arch check!\n");
    } else {
	my $valid_arch;
	for my $a (split(/\s+/, $dscarchs)) {
	    my $command = <<"EOF";
		use strict;
		use warnings;
		use Dpkg::Arch;
		if (Dpkg::Arch::debarch_is("$host_arch", "$a")) {
		    exit 0;
		}
		exit 1;
EOF
	    $self->get('Session')->run_command(
		{ COMMAND => ['perl',
			'-e',
			$command],
		    USER => 'root',
		    PRIORITY => 0,
		    DIR => '/' });
	    if ($? == 0) {
		$valid_arch = 1;
		last;
	    }
	}
	if ($dscarchs ne "any" && !($valid_arch) &&
	    !($dscarchs =~ /\ball\b/ && $self->get_conf('BUILD_ARCH_ALL')) )  {
	    my $msg = "dsc: $host_arch not in arch list or does not match any arch wildcards: $dscarchs -- skipping\n";
	    $self->log_error($msg);
	    Sbuild::Exception::Build->throw(error => "dsc: $host_arch not in arch list or does not match any arch wildcards: $dscarchs -- skipping",
					    status => "skipped",
					    failstage => "arch-check");
	    return 0;
	}
    }

    $self->log("Arch check ok ($host_arch included in $dscarchs)\n");

    return 1;
}

# Subroutine that runs any command through the system (i.e. not through the
# chroot. It takes a string of a command with arguments to run along with
# arguments whether to save STDOUT and/or STDERR to the log stream
sub run_command {
    my $self = shift;
    my $command = shift;
    my $log_output = shift;
    my $log_error = shift;
    my $chroot = shift;
    my $rootuser = shift;

    # Used to determine if we are to log from commands
    my ($out, $err, $defaults);

    # Run the command and save the exit status
	if (!$chroot)
	{
	    $defaults = $self->get('Host')->{'Defaults'};
	    $out = $defaults->{'STREAMOUT'} if ($log_output);
	    $err = $defaults->{'STREAMERR'} if ($log_error);

	    my %args = (PRIORITY  => 0,
			STREAMOUT => $out,
			STREAMERR => $err);
	    if(ref $command) {
		$args{COMMAND} = \@{$command};
		$args{COMMAND_STR} = "@{$command}";
	    } else {
		$args{COMMAND} = [split('\s+', $command)];
		$args{COMMAND_STR} = $command;
	    }

	    $self->get('Host')->run_command( \%args );
	} else {
	    $defaults = $self->get('Session')->{'Defaults'};
	    $out = $defaults->{'STREAMOUT'} if ($log_output);
	    $err = $defaults->{'STREAMERR'} if ($log_error);

	    my %args = (USER => ($rootuser ? 'root' : $self->get_conf('BUILD_USER')),
			PRIORITY => 0,
			STREAMOUT => $out,
			STREAMERR => $err);
	    if(ref $command) {
		$args{COMMAND} = \@{$command};
		$args{COMMAND_STR} = "@{$command}";
	    } else {
		$args{COMMAND} = [split('\s+', $command)];
		$args{COMMAND_STR} = $command;
	    }

	    $self->get('Session')->run_command( \%args );
	}
    my $status = $?;

    # Check if the command failed
    if ($status != 0) {
	return 0;
    }
    return 1;
}

# Subroutine that processes external commands to be run during various stages of
# an sbuild run. We also ask if we want to log any output from the commands
sub run_external_commands {
    my $self = shift;
    my $stage = shift;

    my $log_output = $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT');
    my $log_error  = $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR');

    # Return success now unless there are commands to run
    return 1 unless (${$self->get_conf('EXTERNAL_COMMANDS')}{$stage});

    # Determine which set of commands to run based on the parameter $stage
    my @commands = @{${$self->get_conf('EXTERNAL_COMMANDS')}{$stage}};
    return 1 if !(@commands);

    # Create appropriate log message and determine if the commands are to be
    # run inside the chroot or not, and as root or not.
    my $chroot = 0;
    my $rootuser = 1;
    if ($stage eq "pre-build-commands") {
	$self->log_subsection("Pre Build Commands");
    } elsif ($stage eq "chroot-setup-commands") {
	$self->log_subsection("Chroot Setup Commands");
	$chroot = 1;
    } elsif ($stage eq "chroot-update-failed-commands") {
	$self->log_subsection("Chroot-update Install Failed Commands");
	$chroot = 1;
	$rootuser = 1;
    } elsif ($stage eq "build-deps-failed-commands") {
	$self->log_subsection("Build-Deps Install Failed Commands");
	$chroot = 1;
        $rootuser = 1;
    } elsif ($stage eq "build-failed-commands") {
	$self->log_subsection("Generic Build Failed Commands");
	$chroot = 1;
        $rootuser = 0;
    } elsif ($stage eq "starting-build-commands") {
	$self->log_subsection("Starting Timed Build Commands");
	$chroot = 1;
	$rootuser = 0;
    } elsif ($stage eq "finished-build-commands") {
	$self->log_subsection("Finished Timed Build Commands");
	$chroot = 1;
	$rootuser = 0;
    } elsif ($stage eq "chroot-cleanup-commands") {
	$self->log_subsection("Chroot Cleanup Commands");
	$chroot = 1;
    } elsif ($stage eq "post-build-commands") {
	$self->log_subsection("Post Build Commands");
    }

    # Run each command, substituting the various percent escapes (like
    # %SBUILD_DSC) from the commands to run with the appropriate subsitutions.
    my $hostarch = $self->get('Host Arch');
    my $build_dir = $self->get('Build Dir');
    my $shell_cmd = "bash -i </dev/tty >/dev/tty 2>/dev/tty";
    my %percent = (
	"%" => "%",
	"a" => $hostarch, "SBUILD_HOST_ARCH" => $hostarch,
	"b" => $build_dir, "SBUILD_BUILD_DIR" => $build_dir,
	"s" => $shell_cmd, "SBUILD_SHELL" => $shell_cmd,
    );
    if ($self->get('Changes File')) {
	my $changes = $self->get('Changes File');
	$percent{c} = $changes;
	$percent{SBUILD_CHANGES} = $changes;
    }
    # In case set_version has not been run yet, we do not know the dsc file or
    # directory yet. This can happen if the user only specified a source
    # package name without a version on the command line.
    if ($self->get('DSC Dir')) {
	my $dsc = $self->get('DSC');
	$percent{d} = $dsc;
	$percent{SBUILD_DSC} = $dsc;
	my $pkgbuild_dir = $build_dir . '/' . $self->get('DSC Dir');
	$percent{p} = $pkgbuild_dir;
	$percent{SBUILD_PKGBUILD_DIR} = $pkgbuild_dir;
    }
    if ($chroot == 0) {
	my $chroot_dir = $self->get('Session')->get('Location');
	$percent{r} = $chroot_dir;
	$percent{SBUILD_CHROOT_DIR} = $chroot_dir;
	# the %SBUILD_CHROOT_EXEC escape is only defined when the command is
	# to be run outside the chroot
	my $exec_string = $self->get('Session')->get_internal_exec_string();
	$percent{e} = $exec_string;
	$percent{SBUILD_CHROOT_EXEC} = $exec_string;
    }
    # Our escapes pattern, with longer escapes first, then sorted lexically.
    my $keyword_pat = join("|",
	sort {length $b <=> length $a || $a cmp $b} keys %percent);
    my $returnval = 1;
    foreach my $command (@commands) {

	my $substitute = sub {
	    foreach(@_) {
		if (/\%SBUILD_CHROOT_DIR/ || /\%r/) {
		    $self->log_warning("The %SBUILD_CHROOT_DIR and %r percentage escapes are deprecated and should not be used anymore. Please use %SBUILD_CHROOT_EXEC or %e instead.");
		}
		s{
		     # Match a percent followed by a valid keyword
		     \%($keyword_pat)
	     }{
		 # Substitute with the appropriate value only if it's defined
		 $percent{$1} || $&
	     }msxge;
	    }
	};

	my $command_str;
	if( ref $command ) {
	    $substitute->(@{$command});
	    $command_str = join(" ", @{$command});
	} else {
	    $substitute->($command);
	    $command_str = $command;
	}

	$self->log_subsubsection("$command_str");

	$returnval = $self->run_command($command, $log_output, $log_error, $chroot, $rootuser);
	$self->log("\n");
	if (!$returnval) {
	    $self->log_error("Command '$command_str' failed to run.\n");
	    # do not run any other commands of this type after the first
	    # failure
	    last;
	} else {
	    $self->log_info("Finished running '$command_str'.\n");
	}
    }
    $self->log("\nFinished processing commands.\n");
    $self->log_sep();
    return $returnval;
}

sub run_lintian {
    my $self = shift;
    my $session = $self->get('Session');

    return 1 unless ($self->get_conf('RUN_LINTIAN'));

    if (!defined($session)) {
	$self->log_error("Session is undef. Cannot run lintian.\n");
	return 0;
    }

    $self->log_subsubsection("lintian");

    my $build_dir = $self->get('Build Dir');
    my $resolver = $self->get('Dependency Resolver');
    my $lintian = $self->get_conf('LINTIAN');
    my $changes = $self->get_changes($build_dir);
    if (!defined($changes)) {
	$self->log_error(".changes is undef. Cannot run lintian.\n");
	return 0;
    }

    my @lintian_command = ($lintian);
    push @lintian_command, @{$self->get_conf('LINTIAN_OPTIONS')} if
        ($self->get_conf('LINTIAN_OPTIONS'));
    push @lintian_command, $changes;

    $resolver->add_dependencies('LINTIAN', 'lintian', "", "", "", "", "");
    return 1 unless $resolver->install_core_deps('lintian', 'LINTIAN');

    $session->run_command(
        { COMMAND => \@lintian_command,
          PRIORITY => 0,
          DIR => $self->get('Build Dir')
        });
    my $status = $? >> 8;
    $self->set('Lintian Reason', 'pass');

    $self->log("\n");
    if ($?) {
        my $why = "unknown reason";
	$self->set('Lintian Reason', 'error');
	$self->set('Lintian Reason', 'fail') if ($status == 1);
        $why = "runtime error" if ($status == 2);
        $why = "policy violation" if ($status == 1);
        $why = "received signal " . $? & 127 if ($? & 127);
        $self->log_error("Lintian run failed ($why)\n");

        return 0;
    }

    $self->log_info("Lintian run was successful.\n");
    return 1;
}

sub run_piuparts {
    my $self = shift;

    return 1 unless ($self->get_conf('RUN_PIUPARTS'));

    $self->log_subsubsection("piuparts");

    my $piuparts = $self->get_conf('PIUPARTS');
    my @piuparts_command;
    if (scalar(@{$self->get_conf('PIUPARTS_ROOT_ARGS')})) {
	push @piuparts_command, @{$self->get_conf('PIUPARTS_ROOT_ARGS')};
    } else {
	push @piuparts_command, 'sudo', '--';
    }
    push @piuparts_command, $piuparts;
    push @piuparts_command, @{$self->get_conf('PIUPARTS_OPTIONS')} if
        ($self->get_conf('PIUPARTS_OPTIONS'));
    push @piuparts_command, $self->get('Changes File');
    $self->get('Host')->run_command(
        { COMMAND => \@piuparts_command,
          PRIORITY => 0,
        });
    my $status = $? >> 8;
    $self->set('Piuparts Reason', 'pass');

    $self->log("\n");
    if ($?) {
        $self->log_error("Piuparts run failed.\n");
	$self->set('Piuparts Reason', 'fail');
        return 0;
    }

    $self->log_info("Piuparts run was successful.\n");
    return 1;
}

sub build {
    my $self = shift;

    my $dscfile = $self->get('DSC File');
    my $dscdir = $self->get('DSC Dir');
    my $pkg = $self->get('Package');
    my $build_dir = $self->get('Build Dir');
    my $host_arch = $self->get('Host Arch');
    my $build_arch = $self->get('Build Arch');
    my $session = $self->get('Session');

    my( $rv, $changes );
    local( *PIPE, *F, *F2 );

    $self->log_subsection("Build");
    $self->set('This Space', 0);

    my $tmpunpackdir = $dscdir;
    $tmpunpackdir =~ s/-.*$/.orig.tmp-nest/;
    $tmpunpackdir =~ s/_/-/;
    $tmpunpackdir = "$build_dir/$tmpunpackdir";

    $dscdir = "$build_dir/$dscdir";

    $self->log_subsubsection("Unpack source");
    if ($session->test_directory($dscdir) && $session->test_symlink($dscdir)) {
	# if the package dir already exists but is a symlink, complain
	$self->log_error("Cannot unpack source: a symlink to a directory with the\n".
		   "same name already exists.\n");
	return 0;
    }
    if (!$session->test_directory($dscdir)) {
	$self->set('Sub Task', "dpkg-source");
	$session->run_command({
		COMMAND => [$self->get_conf('DPKG_SOURCE'),
		    '-x', $dscfile, $dscdir],
		USER => $self->get_conf('BUILD_USER'),
		DIR => $build_dir,
		PRIORITY => 0});
	if ($?) {
	    $self->log_error("FAILED [dpkg-source died]\n");
	    Sbuild::Exception::Build->throw(error => "FAILED [dpkg-source died]",
					    failstage => "unpack");
	}

	if (!$session->chmod($dscdir, 'g-s,go+rX', { RECURSIVE => 1 })) {
	    $self->log_error("chmod -R g-s,go+rX $dscdir failed.\n");
	    Sbuild::Exception::Build->throw(error => "chmod -R g-s,go+rX $dscdir failed",
					    failstage => "unpack");
	}
    }
    else {
	$self->log_subsubsection("Check unpacked source");
	# check if the unpacked tree is really the version we need
	my $clog = $session->read_command(
	    { COMMAND => ['dpkg-parsechangelog'],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0,
	      DIR => $dscdir});
	if (!$clog) {
	    $self->log_error("unable to read from dpkg-parsechangelog");
	    Sbuild::Exception::Build->throw(error => "unable to read from dpkg-parsechangelog",
					    failstage => "check-unpacked-version");
	}
	$self->set('Sub Task', "dpkg-parsechangelog");

	if ($clog !~ /^Version:\s*(.+)\s*$/mi) {
	    $self->log_error("dpkg-parsechangelog didn't print Version:\n");
	    Sbuild::Exception::Build->throw(error => "dpkg-parsechangelog didn't print Version:",
					    failstage => "check-unpacked-version");
	}
    }

    $self->log_subsubsection("Check disc space");
    chomp(my $current_usage = $session->read_command({ COMMAND => ["du", "-k", "-s", "$dscdir"]}));
    if ($?) {
	$self->log_error("du exited with non-zero exit status $?");
	Sbuild::Exception::Build->throw(error => "du exited with non-zero exit status $?", failstage => "check-space");
    }
    $current_usage =~ /^(\d+)/;
    $current_usage = $1;
    if ($current_usage) {
	my $pipe = $session->pipe_command({ COMMAND => ["df", "-k", "$dscdir"]});
	my $free;
	while (<$pipe>) {
	    $free = (split /\s+/)[3];
	}
	close $pipe;
	if ($?) {
	    $self->log_error("df exited with non-zero exit status $?");
	    Sbuild::Exception::Build->throw(error => "df exited with non-zero exit status $?", failstage => "check-space");
	}
	if ($free < 2*$current_usage && $self->get_conf('CHECK_SPACE')) {
	    Sbuild::Exception::Build->throw(error => "Disc space is probably not sufficient for building.",
		info => "Source needs $current_usage KiB, while $free KiB is free.)",
		failstage => "check-space");
	} else {
	    $self->log("Sufficient free space for build\n");
	}
    }

    my $clogpipe = $session->pipe_command(
	{ COMMAND => ['dpkg-parsechangelog'],
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0,
	  DIR => $dscdir });
    if (!$clogpipe) {
	    $self->log_error("unable to read from dpkg-parsechangelog");
	    Sbuild::Exception::Build->throw(error => "unable to read from dpkg-parsechangelog",
					    failstage => "check-unpacked-version");
    }

    my $clog = Dpkg::Control->new(type => CTRL_CHANGELOG);
    if (!$clog->parse($clogpipe, "$dscdir/debian/changelog")) {
	$self->log_error("unable to parse debian/changelog");
	Sbuild::Exception::Build->throw(error => "unable to parse debian/changelog",
	    failstage => "check-unpacked-version");
    }

    close($clogpipe);

    my $name = $clog->{Source};
    my $version = $clog->{Version};
    my $dists = $clog->{Distribution};
    my $urgency = $clog->{Urgency};
    my $date = $clog->{Date};

    if ($dists ne $self->get_conf('DISTRIBUTION')) {
	$self->build_log_colour('yellow',
				"^Distribution: " . $self->get_conf('DISTRIBUTION') . "\$");
    }

    if ($self->get_conf('BIN_NMU') || $self->get_conf('APPEND_TO_VERSION')) {
	if (!$self->get_conf('MAINTAINER_NAME')) {
	    Sbuild::Exception::Build->throw(error => "No maintainer specified.",
					    info => 'When making changelog additions for a binNMU or appending a version suffix, a maintainer must be specified for the changelog entry e.g. using $maintainer_name, $uploader_name or $key_id, (or the equivalent command-line options)',
					    failstage => "check-space");
	}

	$self->log_subsubsection("Hack binNMU version");

	my $text = $session->read_file("$dscdir/debian/changelog");

	if (!$text) {
	    $self->log_error("Can't open debian/changelog -- no binNMU hack!\n");
	    Sbuild::Exception::Build->throw(error => "Can't open debian/changelog -- no binNMU hack: $!!",
		failstage => "hack-binNMU");
	}

	my $NMUversion = $self->get('Version');

	my $clogpipe = $session->get_write_file_handle("$dscdir/debian/changelog");

	if (!$clogpipe) {
	    $self->log_error("Can't open debian/changelog for binNMU hack: $!\n");
	    Sbuild::Exception::Build->throw(error => "Can't open debian/changelog for binNMU hack: $!",
		failstage => "hack-binNMU");
	}
	$dists = $self->get_conf('DISTRIBUTION');

	print $clogpipe "$name ($NMUversion) $dists; urgency=low, binary-only=yes\n\n";
	if ($self->get_conf('APPEND_TO_VERSION')) {
	    print $clogpipe "  * Append ", $self->get_conf('APPEND_TO_VERSION'),
	    " to version number; no source changes\n";
	}
	if ($self->get_conf('BIN_NMU')) {
	    print $clogpipe "  * Binary-only non-maintainer upload for $host_arch; ",
	    "no source changes.\n";
	    print $clogpipe "  * ", join( "    ", split( "\n", $self->get_conf('BIN_NMU') )), "\n";
	}
	print $clogpipe "\n";

	print $clogpipe " -- " . $self->get_conf('MAINTAINER_NAME') . "  $date\n\n";
	print $clogpipe $text;
	close($clogpipe);
	$self->log("Created changelog entry for binNMU version $NMUversion\n");
    }

    if ($session->test_regular_file("$dscdir/debian/files")) {
	local( *FILES );
	my @lines;
	my $FILES = $session->get_read_file_handle("$dscdir/debian/files");
	chomp( @lines = <$FILES> );
	close( $FILES );

	$self->log_warning("After unpacking, there exists a file debian/files with the contents:\n");

	$self->log_sep();
	foreach (@lines) {
	    $self->log($_);
	}
	$self->log_sep();
	$self->log("\n");

	$self->log_info("This should be reported as a bug.\n");
	$self->log_info("The file has been removed to avoid dpkg-genchanges errors.\n");

	unlink "$dscdir/debian/files";
    }

    # Build tree not writable during build (except for the sbuild
    # user performing the build).
    if (!$session->chmod($self->get('Build Dir'), 'go-w', { RECURSIVE => 1 })) {
	$self->log_error("chmod og-w " . $self->get('Build Dir') . " failed.\n");
	return 0;
    }

    if (!$self->run_external_commands("starting-build-commands")) {
	Sbuild::Exception::Build->throw(error => "Failed to execute starting-build-commands",
	    failstage => "run-starting-build-commands");
    }

    $self->set('Build Start Time', time);
    $self->set('Build End Time', $self->get('Build Start Time'));

    if ($session->test_regular_file("/etc/ld.so.conf") &&
       ! $session->test_regular_file_readable("/etc/ld.so.conf")) {
	$session->chmod('/etc/ld.so.conf', 'a+r');

	$self->log_subsubsection("Fix ld.so");
	$self->log("ld.so.conf was not readable! Fixed.\n");
    }

    my $buildcmd = [];
    push (@{$buildcmd}, $self->get_conf('BUILD_ENV_CMND'))
	if (defined($self->get_conf('BUILD_ENV_CMND')) &&
	    $self->get_conf('BUILD_ENV_CMND'));
    push (@{$buildcmd}, 'dpkg-buildpackage');

    if ($host_arch ne $build_arch) {
	push (@{$buildcmd}, '-a' . $host_arch);
    }

    if (defined($self->get_conf('BUILD_PROFILES')) &&
	$self->get_conf('BUILD_PROFILES')) {
	my $profiles = $self->get_conf('BUILD_PROFILES');
	$profiles =~ tr/ /,/;
	push (@{$buildcmd}, '-P' . $profiles);
    }

    if (defined($self->get_conf('PGP_OPTIONS')) &&
	$self->get_conf('PGP_OPTIONS')) {
	if (ref($self->get_conf('PGP_OPTIONS')) eq 'ARRAY') {
	    push (@{$buildcmd}, @{$self->get_conf('PGP_OPTIONS')});
        } else {
	    push (@{$buildcmd}, $self->get_conf('PGP_OPTIONS'));
	}
    }

    if (defined($self->get_conf('SIGNING_OPTIONS')) &&
	$self->get_conf('SIGNING_OPTIONS')) {
	if (ref($self->get_conf('SIGNING_OPTIONS')) eq 'ARRAY') {
	    push (@{$buildcmd}, @{$self->get_conf('SIGNING_OPTIONS')});
        } else {
	    push (@{$buildcmd}, $self->get_conf('SIGNING_OPTIONS'));
	}
    }

    use constant dpkgopt => [[["", "-B"], ["-A", "-b" ]], [["-S", "-G"], ["-g", ""]]];
    my $binopt = dpkgopt->[$self->get_conf('BUILD_SOURCE')]
			  [$self->get_conf('BUILD_ARCH_ALL')]
			  [$self->get_conf('BUILD_ARCH_ANY')];
    push (@{$buildcmd}, $binopt) if $binopt;
    push (@{$buildcmd}, "-sa") if ($self->get_conf('BUILD_SOURCE') && $self->get_conf('FORCE_ORIG_SOURCE'));
    push (@{$buildcmd}, "-r" . $self->get_conf('FAKEROOT'));

    if (defined($self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')) &&
	$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')) {
	push (@{$buildcmd}, @{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')});
    }

    # Set up additional build environment variables.
    my %buildenv = %{$self->get_conf('BUILD_ENVIRONMENT')};
    $buildenv{'PATH'} = $self->get_conf('PATH');
    $buildenv{'LD_LIBRARY_PATH'} = $self->get_conf('LD_LIBRARY_PATH')
	if defined($self->get_conf('LD_LIBRARY_PATH'));

	# Add cross environment config
	if ($host_arch ne $build_arch) {
		$buildenv{'CONFIG_SITE'} = "/etc/dpkg-cross/cross-config." . $host_arch;
		if (defined($buildenv{'DEB_BUILD_OPTIONS'})) {
			$buildenv{'DEB_BUILD_OPTIONS'} .= " nocheck";
		} else {
			$buildenv{'DEB_BUILD_OPTIONS'} = "nocheck";
		}
	}

    # Explicitly add any needed environment to the environment filter
    # temporarily for dpkg-buildpackage.
    my @env_filter;
    foreach my $envvar (keys %buildenv) {
	push(@env_filter, "^$envvar\$");
    }

    # Dump build environment
    $self->log_subsubsection("User Environment");
    {
	my $envcmd = $session->read_command(
	    { COMMAND => ['env'],
	      ENV => \%buildenv,
	      ENV_FILTER => \@env_filter,
	      USER => $self->get_conf('BUILD_USER'),
	      SETSID => 1,
	      PRIORITY => 0,
	      DIR => $dscdir
	    });
	if (!$envcmd) {
	    $self->log_error("unable to open pipe");
	    Sbuild::Exception::Build->throw(error => "unable to open pipe",
					    failstage => "dump-build-env");
	}

	my @lines=sort(split /\n/, $envcmd);
	foreach my $line (@lines) {
	    $self->log("$line\n");
	}
    }

    $self->log_subsubsection("dpkg-buildpackage");

    my $command = {
	COMMAND => $buildcmd,
	ENV => \%buildenv,
	ENV_FILTER => \@env_filter,
	USER => $self->get_conf('BUILD_USER'),
	SETSID => 1,
	PRIORITY => 0,
	DIR => $dscdir,
	STREAMERR => \*STDOUT,
    };

    my $pipe = $session->pipe_command($command);
    if (!$pipe) {
	$self->log_error("unable to open pipe");
	Sbuild::Exception::Build->throw(error => "unable to open pipe",
	    failstage => "dpkg-buildpackage");
    }

    $self->set('Sub Task', "dpkg-buildpackage");

    # We must send the signal as root, because some subprocesses of
    # dpkg-buildpackage could run as root. So we have to use a shell
    # command to send the signal... but /bin/kill can't send to
    # process groups :-( So start another Perl :-)
    my $timeout = $self->get_conf('INDIVIDUAL_STALLED_PKG_TIMEOUT')->{$pkg} ||
	$self->get_conf('STALLED_PKG_TIMEOUT');
    $timeout *= 60;
    my $timed_out = 0;
    my(@timeout_times, @timeout_sigs, $last_time);

    local $SIG{'ALRM'} = sub {
	my $pid = $command->{'PID'};
	my $signal = ($timed_out > 0) ? "KILL" : "TERM";
	$session->run_command(
	    { COMMAND => ['perl',
			  '-e',
			  "kill( \"$signal\", -$pid )"],
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });

	$timeout_times[$timed_out] = time - $last_time;
	$timeout_sigs[$timed_out] = $signal;
	$timed_out++;
	$timeout = 5*60; # only wait 5 minutes until next signal
    };

    alarm($timeout);
    while(<$pipe>) {
	alarm($timeout);
	$last_time = time;
	if ($self->get('ABORT')) {
	    my $pid = $command->{'PID'};
	    $session->run_command(
		{ COMMAND => ['perl',
			      '-e',
			      "kill( \"TERM\", -$pid )"],
		  USER => 'root',
		  PRIORITY => 0,
		  DIR => '/' });
	}
	$self->log($_);
    }
    close($pipe);
    alarm(0);
    $rv = $?;

    my $i;
    for( $i = 0; $i < $timed_out; ++$i ) {
	$self->log_error("Build killed with signal " . $timeout_sigs[$i] .
	           " after " . int($timeout_times[$i]/60) .
	           " minutes of inactivity\n");
    }
    $self->set('Build End Time', time);
    $self->set('Pkg End Time', time);
    $self->write_stats('build-time',
		       $self->get('Build End Time')-$self->get('Build Start Time'));
    $self->write_stats('install-download-time',
		       $self->get('Install End Time')-$self->get('Install Start Time'));
    my $finish_date = strftime("%Y%m%d-%H%M",localtime($self->get('Build End Time')));
    $self->log_sep();
    $self->log("Build finished at $finish_date\n");


    if (!$self->run_external_commands("finished-build-commands")) {
	Sbuild::Exception::Build->throw(error => "Failed to execute finished-build-commands",
	    failstage => "run-finished-build-commands");
    }

    my @space_files = ();

    $self->log_subsubsection("Finished");
    if ($rv) {
	$self->log_error("Build failure (dpkg-buildpackage died)\n");
    } else {
	$self->log_info("Built successfully\n");

	if ($session->test_regular_file_readable("$dscdir/debian/files")) {
	    my @files = $self->debian_files_list("$dscdir/debian/files");

	    foreach (@files) {
		if (!$session->test_regular_file("$build_dir/$_")) {
		    $self->log_error("Package claims to have built ".basename($_).", but did not.  This is a bug in the packaging.\n");
		    next;
		}
		if (/_all.u?deb$/ and not $self->get_conf('BUILD_ARCH_ALL')) {
		    $self->log_error("Package builds ".basename($_)." when binary-indep target is not called.  This is a bug in the packaging.\n");
		    $session->unlink("$build_dir/$_");
		    next;
		}
	    }
	}

	# Restore write access to build tree now build is complete.
	if (!$session->chmod($self->get('Build Dir'), 'g+w', { RECURSIVE => 1 })) {
	    $self->log_error("chmod g+w " . $self->get('Build Dir') . " failed.\n");
	    return 0;
	}

	if (!$rv) {
	    $self->log_subsection("Post Build Chroot");

	    # Run lintian.
	    $self->check_abort();
	    $self->run_lintian();
	}

	$self->log_subsection("Changes");
	$changes = $self->get_changes($build_dir);
	if (!defined($changes)) {
	    $self->log_error(".changes is undef. Cannot copy build results.\n");
	    return 0;
	}
	my @cfiles;
	if ($session->test_regular_file_readable("$build_dir/$changes")) {
	    my(@do_dists, @saved_dists);
	    $self->log_subsubsection("$changes:");
	    my $F = $session->get_read_file_handle("$build_dir/$changes");
	    if (!$F) {
		$self->log_error("cannot get read file handle for $build_dir/$changes\n");
		Sbuild::Exception::Build->throw(error => "cannot get read file handle for $build_dir/$changes",
		    failstage => "parse-changes");
	    }
	    my $pchanges = Dpkg::Control->new(type => CTRL_FILE_CHANGES);
	    if (!$pchanges->parse($F, "$build_dir/$changes")) {
		$self->log_error("cannot parse $build_dir/$changes\n");
		Sbuild::Exception::Build->throw(error => "cannot parse $build_dir/$changes",
		    failstage => "parse-changes");
	    }
	    close($F);


	    if ($self->get_conf('OVERRIDE_DISTRIBUTION')) {
		$pchanges->{Distribution} = $self->get_conf('DISTRIBUTION');
	    }

	    my $checksums = Dpkg::Checksums->new();
	    $checksums->add_from_control($pchanges);

	    push(@cfiles, $checksums->get_files());

	    my $sys_build_dir = $self->get_conf('BUILD_DIR');
	    if (!open( F2, ">$sys_build_dir/$changes.new" )) {
		$self->log("Cannot create $sys_build_dir/$changes.new: $!\n");
		$self->log("Distribution field may be wrong!!!\n");
		if ($build_dir) {
		    if(!$session->copy_from_chroot("$build_dir/$changes", ".")) {
			$self->log_error("Could not copy $build_dir/$changes to .\n");
		    }
		}
	    } else {
		$pchanges->output(\*STDOUT);
		$pchanges->output(\*F2);

		close( F2 );
		rename("$sys_build_dir/$changes.new", "$sys_build_dir/$changes")
		    or $self->log("$sys_build_dir/$changes.new could not be " .
		    "renamed to $sys_build_dir/$changes: $!\n");
		$self->set('Changes File', "$sys_build_dir/$changes");
		unlink("$build_dir/$changes")
		    if $build_dir;
	    }
	}
	else {
	    $self->log_error("Can't find $changes -- can't dump info\n");
	}

	$self->log_subsection("Package contents");

	my @debcfiles = @cfiles;
	foreach (@debcfiles) {
	    my $deb = "$build_dir/$_";
	    next if $deb !~ /(\Q$host_arch\E|all)\.(udeb|deb)$/;

	    $self->log_subsubsection("$_");
	    my $dpkg_info = $session->read_command({COMMAND => ["dpkg", "--info", $deb]});
	    if (!$dpkg_info) {
		$self->log_error("Can't spawn dpkg: $! -- can't dump info\n");
	    }
	    else {
		$self->log($dpkg_info);
	    }
	    $self->log("\n");
	    my $dpkg_contents = $session->read_command({COMMAND => ["sh", "-c", "dpkg --contents $deb 2>&1 | sort -k6"]});
	    if (!$dpkg_contents) {
		$self->log_error("Can't spawn dpkg: $! -- can't dump info\n");
	    }
	    else {
		$self->log($dpkg_contents);
	    }
	    $self->log("\n");
	}

	foreach (@cfiles) {
	    push( @space_files, $self->get_conf('BUILD_DIR') . "/$_");
	    if (!$session->copy_from_chroot("$build_dir/$_", $self->get_conf('BUILD_DIR'))) {
		$self->log_error("Could not copy $build_dir/$_ to " . $self->get_conf('BUILD_DIR') . "\n");
	    }
	}
    }

    $self->check_space(@space_files);

    return $rv == 0 ? 1 : 0;
}

# Produce a hash suitable for ENV export
sub get_env ($$) {
    my $self = shift;
    my $prefix = shift;

    sub _env_loop ($$$$) {
	my ($env,$ref,$keysref,$prefix) = @_;

	foreach my $key (keys( %{ $keysref } )) {
	    my $value = $ref->get($key);
	    next if (!defined($value));
	    next if (ref($value));
	    my $name = "${prefix}${key}";
	    $name =~ s/ /_/g;
	    $env->{$name} = $value;
        }
    }

    my $envlist = {};
    _env_loop($envlist, $self, $self, $prefix);
    _env_loop($envlist, $self->get('Config'), $self->get('Config')->{'KEYS'}, "${prefix}CONF_");
    return $envlist;
}

sub get_changes {
    my $self=shift;
    my $path=shift;
    my $changes;
    my $session = $self->get('Session');

    return if not defined($session);

    if ($session->test_regular_file_readable($path . '/' . $self->get('Package_SVersion') . "_source.changes")) {
	$changes = $self->get('Package_SVersion') . "_source.changes";
    }
    elsif ($session->test_regular_file_readable($path . '/' . $self->get('Package_SVersion') . "_all.changes")) {
	$changes = $self->get('Package_SVersion') . "_all.changes";
    }
    else {
	$changes = $self->get('Package_SVersion') . '_' . $self->get('Host Arch') . '.changes';
    }
    return $changes;
}

# same as get_changes but checks for the .changes file on the host running
# sbuild instead of inside the chroot
sub get_changes_host {
    my $self=shift;
    my $path=shift;
    my $changes;

    if ( -r $path . '/' . $self->get('Package_SVersion') . "_source.changes") {
	$changes = $self->get('Package_SVersion') . "_source.changes";
    }
    elsif ( -r $path . '/' . $self->get('Package_SVersion') . "_all.changes") {
	$changes = $self->get('Package_SVersion') . "_all.changes";
    }
    else {
	$changes = $self->get('Package_SVersion') . '_' . $self->get('Host Arch') . '.changes';
    }
    return $changes;
}

sub check_space {
    my $self = shift;
    my @files = @_;
    my $sum = 0;

    my $dscdir = $self->get('DSC Dir');
    my $build_dir = $self->get('Build Dir');
    my $pkgbuilddir = "$build_dir/$dscdir";

    my $pkgbuilddirspc = $self->get('Session')->read_command(
	{ COMMAND => ['du', '-k', '-s', $pkgbuilddir],
	    USER => $self->get_conf('USERNAME'),
	    PRIORITY => 0,
	    DIR => '/'});

    if (!$pkgbuilddirspc) {
	$self->log_error("Cannot determine space needed (du failed)\n");
    }
    if ($pkgbuilddirspc !~ /^(\d+)/) {
	$self->log_error("Cannot determine space needed (unexpected du output): $pkgbuilddirspc\n");
    }
    $sum += $1;

    foreach (@files) {
	my $space = $self->get('Host')->read_command(
	    { COMMAND => ['du', '-k', '-s', $_],
	      USER => $self->get_conf('USERNAME'),
	      PRIORITY => 0,
	      DIR => '/'});

	if (!$space) {
	    $self->log_error("Cannot determine space needed (du failed): $!\n");
	    next;
	}
	if ($pkgbuilddirspc !~ /^(\d+)/) {
	    $self->log_error("Cannot determine space needed (unexpected du output): $space\n");
	}
	$sum += $1;
    }

    $self->set('This Time', $self->get('Pkg End Time') - $self->get('Pkg Start Time'));
    $self->get('This Time') = 0 if $self->get('This Time') < 0;
    $self->set('This Space', $sum);
}

sub lock_file {
    my $self = shift;
    my $file = shift;
    my $for_srcdep = shift;
    my $lockfile = "$file.lock";
    my $try = 0;

  repeat:
    if (!sysopen( F, $lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
	if ($! == EEXIST) {
	    # lock file exists, wait
	    goto repeat if !open( F, "<$lockfile" );
	    my $line = <F>;
	    my ($pid, $user);
	    close( F );
	    if ($line !~ /^(\d+)\s+([\w\d.-]+)$/) {
		$self->log_warning("Bad lock file contents ($lockfile) -- still trying\n");
	    }
	    else {
		($pid, $user) = ($1, $2);
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    # process doesn't exist anymore, remove stale lock
		    $self->log_warning("Removing stale lock file $lockfile ".
				       "(pid $pid, user $user)\n");
		    unlink( $lockfile );
		    goto repeat;
		}
	    }
	    ++$try;
	    if (!$for_srcdep && $try > $self->get_conf('MAX_LOCK_TRYS')) {
		$self->log_warning("Lockfile $lockfile still present after " .
				   $self->get_conf('MAX_LOCK_TRYS') *
				   $self->get_conf('LOCK_INTERVAL') .
				   " seconds -- giving up\n");
		return;
	    }
	    $self->log("Another sbuild process ($pid by $user) is currently installing or removing packages -- waiting...\n")
		if $for_srcdep && $try == 1;
	    sleep $self->get_conf('LOCK_INTERVAL');
	    goto repeat;
	}
	$self->log_warning("Can't create lock file $lockfile: $!\n");
    }

    my $username = $self->get_conf('USERNAME');
    F->print("$$ $username\n");
    F->close();
}

sub unlock_file {
    my $self = shift;
    my $file = shift;
    my $lockfile = "$file.lock";

    unlink( $lockfile );
}

sub add_stat {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    $self->get('Summary Stats')->{$key} = $value;
}

sub generate_stats {
    my $self = shift;
    my $resolver = $self->get('Dependency Resolver');

    $self->add_stat('Job', $self->get('Job'));
    $self->add_stat('Package', $self->get('Package'));
    # If the package fails early, then the version might not yet be known.
    # This can happen if the user only specified a source package name on the
    # command line and then the version will only be known after the source
    # package was successfully downloaded.
    if ($self->get('Version')) {
	$self->add_stat('Version', $self->get('Version'));
    }
    if ($self->get('OVersion')) {
	$self->add_stat('Source-Version', $self->get('OVersion'));
    }
    $self->add_stat('Machine Architecture', $self->get_conf('ARCH'));
    $self->add_stat('Host Architecture', $self->get('Host Arch'));
    $self->add_stat('Build Architecture', $self->get('Build Arch'));
    $self->add_stat('Build Profiles', $self->get('Build Profiles'))
        if $self->get('Build Profiles');
    my @keylist;
    if (defined $resolver) {
	@keylist=keys %{$resolver->get('Initial Foreign Arches')};
	push @keylist, keys %{$resolver->get('Added Foreign Arches')};
    }
    my $foreign_arches = join ' ', @keylist;
    $self->add_stat('Foreign Architectures', $foreign_arches )
        if $foreign_arches;
    $self->add_stat('Distribution', $self->get_conf('DISTRIBUTION'));
    $self->add_stat('Space', $self->get('This Space'));
    $self->add_stat('Build-Time',
		    $self->get('Build End Time')-$self->get('Build Start Time'));
    $self->add_stat('Install-Time',
		    $self->get('Install End Time')-$self->get('Install Start Time'));
    $self->add_stat('Package-Time',
		    $self->get('Pkg End Time')-$self->get('Pkg Start Time'));
    $self->add_stat('Build-Space', $self->get('This Space'));
    $self->add_stat('Status', $self->get_status());
    $self->add_stat('Fail-Stage', $self->get('Pkg Fail Stage'))
	if ($self->get_status() ne "successful");
    $self->add_stat('Lintian', $self->get('Lintian Reason'))
	if $self->get('Lintian Reason');
    $self->add_stat('Piuparts', $self->get('Piuparts Reason'))
	if $self->get('Piuparts Reason');
}

sub log_stats {
    my $self = shift;
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	$self->log("${stat}: " . $self->get('Summary Stats')->{$stat} . "\n");
    }
}

sub print_stats {
    my $self = shift;
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	print STDOUT "${stat}: " . $self->get('Summary Stats')->{$stat} . "\n";
    }
}

sub write_stats {
    my $self = shift;

    return if (!$self->get_conf('BATCH_MODE'));

    my $stats_dir = $self->get_conf('STATS_DIR');

    return if not defined $stats_dir;

    if (! -d $stats_dir &&
	!mkdir $stats_dir) {
	$self->log_warning("Could not create $stats_dir: $!\n");
	return;
    }

    my ($cat, $val) = @_;
    local( *F );

    $self->lock_file($stats_dir, 0);
    open( F, ">>$stats_dir/$cat" );
    print F "$val\n";
    close( F );
    $self->unlock_file($stats_dir);
}

sub debian_files_list {
    my $self = shift;
    my $files = shift;

    my @list;

    debug("Parsing $files\n");
    my $session = $self->get('Session');

    my $pipe = $session->get_read_file_handle($files);
    if ($pipe) {
	while (<$pipe>) {
	    chomp;
	    my $f = (split( /\s+/, $_ ))[0];
	    push( @list, "$f" );
	    debug("  $f\n");
	}
	close( $pipe ) or $self->log_error("Failed to close $files\n") && return 1;
    }

    return @list;
}

# Figure out chroot architecture
sub chroot_arch {
    my $self = shift;

    chomp(my $chroot_arch = $self->get('Session')->read_command(
	{ COMMAND => ['dpkg', '--print-architecture'],
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0,
	  DIR => '/' }));

    if (!$chroot_arch) {
	Sbuild::Exception::Build->throw(error => "Can't determine architecture of chroot: $!",
	    failstage => "chroot-arch")
    }

    return $chroot_arch;
}

sub build_log_filter {
    my $self = shift;
    my $text = shift;
    my $replacement = shift;

    if ($self->get_conf('LOG_FILTER')) {
	$self->log($self->get('FILTER_PREFIX') . $text . ':' . $replacement . "\n");
    }
}

sub build_log_colour {
    my $self = shift;
    my $regex = shift;
    my $colour = shift;

    if ($self->get_conf('LOG_COLOUR')) {
	$self->log($self->get('COLOUR_PREFIX') . $colour . ':' . $regex . "\n");
    }
}

sub open_build_log {
    my $self = shift;

    my $date = strftime("%Y%m%d-%H%M", localtime($self->get('Pkg Start Time')));

    my $filter_prefix = '__SBUILD_FILTER_' . $$ . ':';
    $self->set('FILTER_PREFIX', $filter_prefix);
    my $colour_prefix = '__SBUILD_COLOUR_' . $$ . ':';
    $self->set('COLOUR_PREFIX', $colour_prefix);

    my $filename = $self->get_conf('LOG_DIR') . '/';
    # we might not know the pkgname_ver string if the user only specified a
    # package name without version
    if ($self->get('Package_SVersion')) {
	$filename .= $self->get('Package_SVersion');
    } else {
	$filename .= $self->get('Package');
    }
    $filename .= '_' . $self->get('Host Arch') . "-$date";
    $filename .= ".build" if $self->get_conf('SBUILD_MODE') ne 'buildd';

    open($saved_stdout, ">&STDOUT") or warn "Can't redirect stdout\n";
    open($saved_stderr, ">&STDERR") or warn "Can't redirect stderr\n";

    my $PLOG;

    my $pid;
    ($pid = open($PLOG, "|-"));
    if (!defined $pid) {
	warn "Cannot open pipe to '$filename': $!\n";
    } elsif ($pid == 0) {
	$SIG{'INT'} = 'IGNORE';
	$SIG{'TERM'} = 'IGNORE';
	$SIG{'QUIT'} = 'IGNORE';
	$SIG{'PIPE'} = 'IGNORE';

	$saved_stdout->autoflush(1);
	if (!$self->get_conf('NOLOG') &&
	    $self->get_conf('LOG_DIR_AVAILABLE')) {
	    unlink $filename; # To prevent opening symlink to elsewhere
	    open( CPLOG, ">$filename" ) or
		Sbuild::Exception::Build->throw(error => "Failed to open build log $filename: $!",
						failstage => "init");
	    CPLOG->autoflush(1);

	    # Create 'current' symlinks
	    if ($self->get_conf('SBUILD_MODE') eq 'buildd') {
		$self->log_symlink($filename,
				   $self->get_conf('BUILD_DIR') . '/current-' .
				   $self->get_conf('DISTRIBUTION'));
	    } else {
		my $symlinktarget = $filename;
		# if symlink target is in the same directory as the symlink
		# itself, make it a relative link instead of an absolute one
		if (Cwd::abs_path($self->get_conf('BUILD_DIR')) eq Cwd::abs_path(dirname($filename))) {
		    $symlinktarget = basename($filename)
		}
		my $symlinkname = $self->get_conf('BUILD_DIR') . '/';
		# we might not know the pkgname_ver string if the user only specified a
		# package name without version
		if ($self->get('Package_SVersion')) {
		    $symlinkname .= $self->get('Package_SVersion');
		} else {
		    $symlinkname .= $self->get('Package');
		}
		$symlinkname .= '_' . $self->get('Host Arch') . ".build";
		$self->log_symlink($symlinktarget, $symlinkname);
	    }
	}

	# Cache vars to avoid repeated hash lookups.
	my $nolog = $self->get_conf('NOLOG');
	my $log = $self->get_conf('LOG_DIR_AVAILABLE');
	my $verbose = $self->get_conf('VERBOSE');
	my $log_colour = $self->get_conf('LOG_COLOUR');
	my @filter = ();
	my @colour = ();
	my ($text, $replacement);
	my $filter_regex = "^$filter_prefix(.*):(.*)\$";
	my $colour_regex = "^$colour_prefix(.*):(.*)\$";
	my @ignore = ();

	while (<STDIN>) {
	    # Add a replacement pattern to filter (sent from main
	    # process in log stream).
	    if (m/$filter_regex/) {
		($text,$replacement)=($1,$2);
		$replacement = "<<$replacement>>";
		push (@filter, [$text, $replacement]);
		$_ = "I: NOTICE: Log filtering will replace '$text' with '$replacement'\n";
	    } elsif (m/$colour_regex/) {
		my ($colour, $regex);
		($colour,$regex)=($1,$2);
		push (@colour, [$colour, $regex]);
#		$_ = "I: NOTICE: Log colouring will colour '$regex' in $colour\n";
		next;
	    } else {
		# Filter out any matching patterns
		foreach my $pattern (@filter) {
		    ($text,$replacement) = @{$pattern};
		    s/$text/$replacement/g;
		}
	    }
	    if (m/Deprecated key/ || m/please update your configuration/) {
		my $skip = 0;
		foreach my $ignore (@ignore) {
		    $skip = 1 if ($ignore eq $_);
		}
		next if $skip;
		push(@ignore, $_);
	    }

	    if ($nolog || $verbose) {
		if (-t $saved_stdout && $log_colour) {
		    my $colour = 'reset';
		    foreach my $pattern (@colour) {
			if (m/$$pattern[0]/) {
			    $colour = $$pattern[1];
			}
		    }
		    print $saved_stdout color $colour;
		}

		print $saved_stdout $_;
		if (-t $saved_stdout && $log_colour) {
		    print $saved_stdout color 'reset';
		}
	    }
	    if (!$nolog && $log) {
		    print CPLOG $_;
	    }
	}

	close CPLOG;
	exit 0;
    }

    $PLOG->autoflush(1);
    open(STDOUT, '>&', $PLOG) or warn "Can't redirect stdout\n";
    open(STDERR, '>&', $PLOG) or warn "Can't redirect stderr\n";
    $self->set('Log File', $filename);
    $self->set('Log Stream', $PLOG);

    my $hostname = $self->get_conf('HOSTNAME');
    $self->log("sbuild (Debian sbuild) $version ($release_date) on $hostname\n");

    my $arch_string = $self->get('Build Arch');
    $arch_string = 'CROSS host=' . $self->get('Host Arch') .
	'/build=' . $self->get('Build Arch')
	if ($self->get('Host Arch') ne $self->get('Build Arch'));
    my $head1 = $self->get('Package');
    if ($self->get('Version')) {
	$head1 .= ' ' . $self->get('Version');
    }
    $head1 .= ' (' . $arch_string . ') ';
    my $head2 = strftime("%d %b %Y %H:%M",
			 localtime($self->get('Pkg Start Time')));
    my $head = $head1 . ' ' x (80 - 4 - length($head1) - length($head2)) .
	$head2;
    $self->log_section($head);

    $self->log("Package: " . $self->get('Package') . "\n");
    if ($self->get('Version') && $self->get('OVersion')) {
	$self->log("Version: " . $self->get('Version') . "\n");
	$self->log("Source Version: " . $self->get('OVersion') . "\n");
    }
    $self->log("Distribution: " . $self->get_conf('DISTRIBUTION') . "\n");
    $self->log("Machine Architecture: " . $self->get_conf('ARCH') . "\n");
    $self->log("Host Architecture: " . $self->get('Host Arch') . "\n");
    $self->log("Build Architecture: " . $self->get('Build Arch') . "\n");
    $self->log("Build Profiles: " . $self->get('Build Profiles') . "\n") if $self->get('Build Profiles');
    $self->log("\n");
}

sub close_build_log {
    my $self = shift;

    my $time = $self->get('Pkg End Time');
    if ($time == 0) {
        $time = time;
    }
    my $date = strftime("%Y%m%d-%H%M", localtime($time));

    my $hours = int($self->get('This Time')/3600);
    my $minutes = int(($self->get('This Time')%3600)/60),
    my $seconds = int($self->get('This Time')%60),
    my $space = $self->get('This Space');

    my $filename = $self->get('Log File');

    # building status at this point means failure.
    if ($self->get_status() eq "building") {
	$self->set_status('failed');
    }

    $self->log_subsection('Summary');
    $self->generate_stats();
    $self->log_stats();

    $self->log_sep();
    $self->log("Finished at ${date}\n");
    $self->log(sprintf("Build needed %02d:%02d:%02d, %dk disc space\n",
	       $hours, $minutes, $seconds, $space));

    if ($self->get_status() eq "successful") {
	if (defined($self->get_conf('KEY_ID')) && $self->get_conf('KEY_ID')) {
	    my $key_id = $self->get_conf('KEY_ID');
	    my $build_dir = $self->get_conf('BUILD_DIR');
	    my $changes;
	    $self->log(sprintf("Signature with key '%s' requested:\n", $key_id));
	    $changes = $self->get_changes_host($build_dir);
	    if (!defined($changes)) {
		$self->log_error(".changes is undef. Cannot sign .changes.\n");
	    } else {
		system('debsign', "-k$key_id", '--', "$build_dir/$changes");
	    }
	}
    }

    my $subject = "Log for " . $self->get_status() . " build of ";
    if ($self->get('Package_Version')) {
	$subject .= $self->get('Package_Version');
    } else {
	$subject .= $self->get('Package');
    }

    if ($self->get_conf('BUILD_SOURCE') && !$self->get_conf('BUILD_ARCH_ALL') && !$self->get_conf('BUILD_ARCH_ANY')) {
	$subject .= " source";
    }
    if ($self->get_conf('BUILD_ARCH_ALL') && !$self->get_conf('BUILD_ARCH_ANY')) {
	$subject .= " on all";
    } elsif ($self->get('Host Arch')) {
	$subject .= " on " . $self->get('Host Arch');
    }
    if ($self->get_conf('ARCHIVE')) {
	$subject .= " (" . $self->get_conf('ARCHIVE') . "/" . $self->get_conf('DISTRIBUTION') . ")";
    }
    else {
	    $subject .= " (dist=" . $self->get_conf('DISTRIBUTION') . ")";
    }

    open(STDERR, '>&', $saved_stderr) or warn "Can't redirect stderr\n"
	if defined($saved_stderr);
    open(STDOUT, '>&', $saved_stdout) or warn "Can't redirect stdout\n"
	if defined($saved_stdout);
    $saved_stderr->close();
    undef $saved_stderr;
    $saved_stdout->close();
    undef $saved_stdout;
    $self->set('Log File', undef);
    if (defined($self->get('Log Stream'))) {
	$self->get('Log Stream')->close(); # Close child logger process
	$self->set('Log Stream', undef);
    }

    $self->send_build_log($self->get_conf('MAILTO'), $subject, $filename)
	if (defined($filename) && -f $filename &&
	    $self->get_conf('MAILTO'));
}

sub send_build_log {
    my $self = shift;
    my $to = shift;
    my $subject = shift;
    my $filename = shift;

    my $conf = $self->get('Config');

    if ($conf->get('MIME_BUILD_LOG_MAILS')) {
	return $self->send_mime_build_log($to, $subject, $filename);
    } else {
        return send_mail($conf, $to, $subject, $filename);
    }
}

sub send_mime_build_log {
    my $self = shift;
    my $to = shift;
    my $subject = shift;
    my $filename = shift;

    my $conf = $self->get('Config');
    my $tmp; # Needed for gzip, here for proper scoping.

    my $msg = MIME::Lite->new(
	    From    => $conf->get('MAILFROM'),
	    To      => $to,
	    Subject => $subject,
	    Type    => 'multipart/mixed'
	    );

    # Add the GPG key ID to the mail if present so that it's clear if the log
    # still needs signing or not.
    if (defined($self->get_conf('KEY_ID')) && $self->get_conf('KEY_ID')) {
	$msg->add('Key-ID', $self->get_conf('KEY_ID'));
    }

    if (!$conf->get('COMPRESS_BUILD_LOG_MAILS')) {
	my $log_part = MIME::Lite->new(
		Type     => 'text/plain',
		Path     => $filename,
		Filename => basename($filename)
		);
	$log_part->attr('content-type.charset' => 'UTF-8');
	$msg->attach($log_part);
    } else {
	local( *F, *GZFILE );

	if (!open( F, "<$filename" )) {
	    warn "Cannot open $filename for mailing: $!\n";
	    return 0;
	}

	$tmp = File::Temp->new();
	tie *GZFILE, 'IO::Zlib', $tmp->filename, 'wb';

	while( <F> ) {
	    print GZFILE $_;
	}
	untie *GZFILE;

	close F;
	close GZFILE;

	$msg->attach(
		Type     => 'application/x-gzip',
		Path     => $tmp->filename,
		Filename => basename($filename) . '.gz'
		);
    }
    my $build_dir = $self->get_conf('BUILD_DIR');
    my $changes = $self->get_changes_host($build_dir);
    if ($self->get_status() eq 'successful' && -r "$build_dir/$changes") {
	my $log_part = MIME::Lite->new(
		Type     => 'text/plain',
		Path     => "$build_dir/$changes",
		Filename => basename($changes)
		);
	$log_part->attr('content-type.charset' => 'UTF-8');
	$msg->attach($log_part);
    }

    my $stats = '';
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	$stats .= sprintf("%s: %s\n", $stat, $self->get('Summary Stats')->{$stat});
    }
    $msg->attach(
	Type => 'text/plain',
	Filename => basename($filename) . '.summary',
	Data => $stats
	);

    local $SIG{'PIPE'} = 'IGNORE';

    if (!open( MAIL, "|" . $conf->get('MAILPROG') . " -oem $to" )) {
	warn "Could not open pipe to " . $conf->get('MAILPROG') . ": $!\n";
	close( F );
	return 0;
    }

    $msg->print(\*MAIL);

    if (!close( MAIL )) {
	warn $conf->get('MAILPROG') . " failed (exit status $?)\n";
	return 0;
    }
    return 1;
}

sub log_symlink {
    my $self = shift;
    my $log = shift;
    my $dest = shift;

    unlink $dest; # Don't return on failure, since the symlink will fail.
    symlink $log, $dest;
}

1;
