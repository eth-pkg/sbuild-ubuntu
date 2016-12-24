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

package Sbuild::ChrootSudo;

use strict;
use warnings;

use Sbuild qw(shellescape);
use Sbuild::Sysconfig;

BEGIN {
    use Exporter ();
    use Sbuild::Chroot;
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Chroot);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf, $chroot_id);
    bless($self, $class);

    return $self;
}

sub begin_session {
    my $self = shift;
    my $chroot = $self->get('Chroot ID');

    return 0 if !defined $chroot;

    my $info = $self->get('Chroots')->get_info($chroot);

    print STDERR "Setting up chroot $chroot\n"
	if $self->get_conf('DEBUG');

    if (defined($info) &&
	defined($info->{'Location'}) && -d $info->{'Location'}) {
	$self->set('Priority', $info->{'Priority'});
	$self->set('Location', $info->{'Location'});
	$self->set('Session Purged', $info->{'Session Purged'});
    } else {
	die $self->get('Chroot ID') . " chroot does not exist\n";
    }

    return 0 if !$self->_setup_options();

    return 1;
}

sub end_session {
    my $self = shift;

    # No-op for sudo.

    return 1;
}

sub get_command_internal {
    my $self = shift;
    my $options = shift;

    # Command to run. If I have a string, use it. Otherwise use the list-ref
    my $command = $options->{'INTCOMMAND_STR'} // $options->{'INTCOMMAND'};

    my $user = $options->{'USER'};          # User to run command under
    my $dir;                                # Directory to use (optional)
    $dir = $self->get('Defaults')->{'DIR'} if
	(defined($self->get('Defaults')) &&
	 defined($self->get('Defaults')->{'DIR'}));
    $dir = $options->{'DIR'} if
	defined($options->{'DIR'}) && $options->{'DIR'};

    if (!defined $user || $user eq "") {
	$user = $self->get_conf('USERNAME');
    }

    my @cmdline;

    if (!defined($dir)) {
	$dir = '/';
    }

    @cmdline = ($self->get_conf('SUDO'), '/usr/sbin/chroot', $self->get('Location'),
		$self->get_conf('SU'), "$user", '-s');

    if( ref $command ) {
        my $shellcommand;
        foreach (@$command) {
            my $tmp = $_;
            if ($shellcommand) {
                $shellcommand .= " " . shellescape $tmp;
            } else {
                $shellcommand = shellescape $tmp;
            }
        }
        push(@cmdline, '/bin/sh', '-c', "cd " . (shellescape $dir) . " && $shellcommand");
    } else {
        push(@cmdline, '/bin/sh', '-c', "cd " . (shellescape $dir) . " && ( $command )");
    }

    $options->{'USER'} = $user;
    $options->{'COMMAND'} = ref($command) ? $command : [split(/\s+/, $command)];
    $options->{'EXPCOMMAND'} = \@cmdline;
    $options->{'CHDIR'} = undef;
    $options->{'DIR'} = $dir;
}

1;
