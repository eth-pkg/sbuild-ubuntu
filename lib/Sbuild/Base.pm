#
# Base.pm: base class containing common class infrastructure
# Copyright © 2008 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Base;

use strict;
use warnings;

use Sbuild qw(debug);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self  = {};
    bless($self, $class);

    $self->set('Config', $conf);

    return $self;
}

sub get {
    my $self = shift;
    my $key = shift;

    return $self->{$key};
}

sub set {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    if (defined($value)) {
	debug("Setting $key=$value\n");
    } else {
	debug("Setting $key=undef\n");
    }

    return $self->{$key} = $value;
}

sub get_conf {
    my $self = shift;
    my $key = shift;

    return $self->get('Config')->get($key);
}

sub set_conf {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->get('Config')->set($key,$value);
}

sub log {
    my $self = shift;

    my $logfile = $self->get('Log Stream');
    if (defined($logfile)) {
	print $logfile @_;
    } else {
	debug("E: Attempt to log to nonexistent log stream\n")
	    if (!defined($self->get('Log Stream Error')) ||
		!$self->get('Log Stream Error'));
	print STDERR @_;
	$self->set('Log Stream Error', 1)
    }
}

sub log_info {
    my $self = shift;

    $self->log("I: ", @_);
}

sub log_warning {
    my $self = shift;

    $self->log("W: ", @_);
}

sub log_error {
    my $self = shift;

    $self->log("E: ", @_);
}

sub log_section {
    my $self = shift;
    my $section = shift;

    $self->log("\n");
    $self->log('+', '=' x 78, '+', "\n");
    $self->log('|', " $section ", ' ' x (80 - length($section) - 4), '|', "\n");
    $self->log('+', '=' x 78, '+', "\n\n");
}

sub log_subsection {
    my $self = shift;
    my $section = shift;

    $self->log("\n");
    $self->log('+', '-' x 78, '+', "\n");
    $self->log('|', " $section ", ' ' x (80 - length($section) - 4), '|', "\n");
    $self->log('+', '-' x 78, '+', "\n\n");
}

sub log_subsubsection {
    my $self = shift;
    my $section = shift;

    $self->log("\n");
    $self->log("$section\n");
    $self->log('-' x (length($section)), "\n\n");
}

sub log_sep {
    my $self = shift;

    $self->log('-' x 80, "\n");
}

1;
