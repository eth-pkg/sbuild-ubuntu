#
# ChrootInfo.pm: chroot utility library for sbuild
# Copyright © 2005-2009 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootInfoSchroot;

use Sbuild::ChrootInfo;
use Sbuild::ChrootSchroot;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ChrootInfo);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    return $self;
}

sub get_info_from_stream {
    my $self = shift;
    my $stream = shift;

    my $chroot_type = '';
    my %tmp = ('Name' => '',
	       'Priority' => 0,
	       'Location' => '',
	       'Session Purged' => 0);

    while (<$stream>) {
	chomp;

	last if ! $_;

	if (/^\s*Name:?\s+(.*)$/ &&
	    $tmp{'Name'} eq "") {
	    $tmp{'Name'} = $1;
	}
	if (/^\s*Type:?\s+(.*)$/) {
	    $chroot_type = $1;
	}
	if (/^\s*Location:?\s+(.*)$/ &&
	    $tmp{'Location'} eq "") {
	    $tmp{'Location'} = $1;
	}
	if (/^\s*Mount Location:?\s+(.*)$/ &&
	    $tmp{'Location'} eq "") {
	    $tmp{'Location'} = $1;
	}
	# Path takes priority over Location and Mount Location.
	if (/^\s*Path:?\s+(.*)$/) {
	    $tmp{'Location'} = $1;
	}
	if (/^\s*Priority:?\s+(\d+)$/) {
	    $tmp{'Priority'} = $1;
	}
	if (/^\s*Session Purged\s+(.*)$/) {
	    if ($1 eq "true") {
		$tmp{'Session Purged'} = 1;
	    }
	}
	if (/^\s*Aliases:?\s+(.*)$/) {
	    $tmp{'Aliases'} = $1;
	}
    }

    if ($self->get_conf('DEBUG')) {
	print STDERR "Found schroot chroot: $tmp{'Name'}\n";
	foreach (sort keys %tmp) {
	    print STDERR "  $_ $tmp{$_}\n";
	}
    }

    return \%tmp;
}

sub get_info {
    my $self = shift;
    my $chroot = shift;

    my $chroot_type = "";

    open CHROOT_DATA, '-|', $self->get_conf('SCHROOT'), '--info', '--chroot', $chroot
	or die 'Can\'t run ' . $self->get_conf('SCHROOT') . ' to get chroot data';

    my $tmp = $self->get_info_from_stream(\*CHROOT_DATA);

    close CHROOT_DATA or die "Can't close schroot pipe getting chroot data";

    return $tmp;
}

sub get_info_all {
    my $self = shift;

    my $chroots = {};
    my $build_dir = $self->get_conf('BUILD_DIR');

    local %ENV;

    $ENV{'LC_ALL'} = 'C';
    $ENV{'LANGUAGE'} = 'C';

    open CHROOTS, '-|', $self->get_conf('SCHROOT'), '--info', '--all-chroots'
	or die 'Can\'t run ' . $self->get_conf('SCHROOT');
    while (<CHROOTS>) {
	my $tmp = $self->get_info_from_stream(\*CHROOTS);
	$chroots->{$tmp->{'Name'}} = $tmp;
	foreach my $alias (split(/\s+/, $tmp->{'Aliases'})) {
	    $chroots->{$alias} = $tmp;
	}
    }
    close CHROOTS or die "Can't close schroot pipe";

    $self->set('Chroots', $chroots);
}

sub find {
    my $self = shift;
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;

    # Determine the chroot type given
    my $chroot_type;
    if ($distribution =~ /:/) {
        ($chroot_type = $distribution) =~ s/^([^:]+?):.*/$1/;
    }
    if (!$chroot_type && ($distribution =~ /-source$/)) {
        $chroot_type = "source";
    }

    # Strip namespaces and '-source' suffix from distribution name given.
    $distribution =~ s/^[^:]+://;
    $distribution =~ s/-source$//;

    # Call parent find() subroutine
    $chroot = $self->SUPER::find($distribution, $chroot, $arch);

    # Add chroot type if defined
    if ($chroot_type) {
        $chroot = "$chroot_type:" . "$chroot";
    }

    return $chroot;
}

sub _create {
    my $self = shift;
    my $chroot_id = shift;

    my $chroot = undef;

    if (defined($chroot_id)) {
	$chroot = Sbuild::ChrootSchroot->new($self->get('Config'), $chroot_id);
    }

    return $chroot;
}

1;
