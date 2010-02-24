#
# Conf.pm: configuration library for buildd
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2009 Roger Leigh <rleigh@debian.org>
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

package Buildd::UploadQueueConf;

use strict;
use warnings;

use Sbuild::ConfBase;
use Sbuild::Sysconfig;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ConfBase);
}

sub new {
    my $class = shift;
    my $data_hash = shift;

    my $self  = {};
    $self->{'config'} = {};
    bless($self, $class);

    $self->init_allowed_keys();
    $self->_fill_from_hash($data_hash);

    return $self;
}


sub init_allowed_keys {
    my $self = shift;

    $self->SUPER::init_allowed_keys();

    my $validate_directory_in_home = sub {
	my $self = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $directory = $self->get($key);
	my $home_directory = $self->get('HOME');

	die "$key directory is not defined"
	    if !defined($directory) || !$directory;

	die "$key directory '$home_directory/$directory' does not exist"
	    if !-d $home_directory . "/" . $directory;
    };

    my %dupload_queue_keys = (
	'DUPLOAD_LOCAL_QUEUE_DIR'		=> {
	    CHECK => $validate_directory_in_home,
	    DEFAULT => 'upload'
	},
	'DUPLOAD_ARCHIVE_NAME'		=> {
	    DEFAULT => 'anonymous-ftp-master'
	},
    );

    $self->set_allowed_keys(\%dupload_queue_keys);

    Sbuild::DB::ClientConf::add_keys($self);
}

sub _fill_from_hash($) {
    my $self = shift;
    my $data = shift;

    for my $key (keys %$data) {
	$self->set($key, $data->{$key});
    }
}
1;
