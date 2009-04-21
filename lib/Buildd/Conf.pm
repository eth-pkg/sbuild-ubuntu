#
# Conf.pm: configuration library for buildd
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2008 Roger Leigh <rleigh@debian.org>
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

package Buildd::Conf;

use strict;
use warnings;
use Cwd qw(cwd);
use Buildd;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw($HOME $arch $max_build $nice_level $idle_sleep_time
                 $min_free_space @take_from_dists @no_auto_build
                 $no_build_regex $build_regex @weak_no_auto_build
                 $delay_after_give_back $pkg_log_keep $pkg_log_keep
                 $build_log_keep $daemon_log_rotate $daemon_log_send
                 $daemon_log_keep $warning_age $error_mail_window
                 $statistics_period $sshcmd $wanna_build_user
                 $no_warn_pattern $should_build_msgs apt_get sudo
                 $autoclean_interval $secondary_daemon_threshold
                 $admin_mail $statistics_mail $dupload_to
                 $dupload_to_non_us $dupload_to_security
                 $log_queued_messages $wanna_build_dbbase read);
}

sub read_file ($\$);
sub read ();
sub convert_sshcmd ();
sub init ();

my $reread_config = 0;

# Originally from the main namespace.
(our $HOME = $ENV{'HOME'})
    or die "HOME not defined in environment!\n";
# Configuration files.
my $config_global = "/etc/buildd.conf";
my $config_user = "$HOME/.builddrc";
my $config_global_time = 0;
my $config_user_time = 0;

# Defaults.
chomp( our $arch = `dpkg --print-architecture 2>/dev/null` );
our $max_build = 10;
our $nice_level = 10;
our $idle_sleep_time = 5*60;
our $min_free_space = 50*1024;
our @take_from_dists = qw();
our @no_auto_build = ();
our $no_build_regex = "^(contrib/|non-free/)?non-US/";
our $build_regex = "";
our @weak_no_auto_build = ();
our $delay_after_give_back = 8 * 60; # 8 hours
our $pkg_log_keep = 7;
our $build_log_keep = 2;
our $daemon_log_rotate = 1;
our $daemon_log_send = 1;
our $daemon_log_keep = 7;
our $warning_age = 7;
our $error_mail_window = 8*60*60;
our $statistics_period = 7;
our $sshcmd = "";
our $sshsocket = "";
our $wanna_build_user = $Buildd::username;
our $no_warn_pattern = '^build/(SKIP|REDO|SBUILD-GIVEN-BACK|buildd\.pid|[^/]*.ssh|chroot-[^/]*)$';
our $should_build_msgs = 1;
our $apt_get = "/usr/bin/apt-get";
our $sudo = "/usr/bin/sudo";
our $autoclean_interval = 86400;
our $secondary_daemon_threshold = 70;
our $admin_mail = "USER-porters";
our $statistics_mail = 'USER-porters';
our $dupload_to = "anonymous-ftp-master";
our $dupload_to_non_us = "anonymous-non-us";
our $dupload_to_security = "security";
our $log_queued_messages = 0;
our $wanna_build_dbbase = "$arch/build-db";

sub ST_MTIME () { 9 }

sub read_file ($\$) {
    my $filename = shift;
    my $time_var = shift;
    if (-r $filename) {
        my @stat = stat( $filename );
        $$time_var = $stat[ST_MTIME];
        delete $INC{$filename};
        require $filename;
    }
}

# read conf files
sub read () {
    read_file( $config_global, $config_global_time );
    read_file( $config_user, $config_user_time );
    convert_sshcmd();
}

sub convert_sshcmd () {
    if ($sshcmd) {
	if ($sshcmd =~ /-l\s*(\S+)\s+(\S+)/) {
	    ($main::sshuser, $main::sshhost) = ($1, $2);
	}
	elsif ($sshcmd =~ /(\S+)\@(\S+)/) {
	    ($main::sshuser, $main::sshhost) = ($1, $2);
	}
	else {
	    $sshcmd =~ /(\S+)\s*$/;
	    ($main::sshuser, $main::sshhost) = ("", $1);
	}
	if ($sshsocket) {
	    $sshcmd .= " -S $sshsocket";
	}
    }
}

sub init () {
    Buildd::Conf::read();
}

$SIG{'USR1'} = sub ($) { $reread_config = 1; };

sub check_reread_config () {
    my @stat_user = stat( $config_user );
    my @stat_global = stat( $config_global );

    if ( $reread_config ||
        (@stat_user && $config_user_time != $stat_user[ST_MTIME]) ||
        (@stat_global && $config_global_time != $stat_global[ST_MTIME])) {
        logger( "My config file has been updated -- rereading it\n" );
        Buildd::Conf::read();
        $reread_config = 0;
    }
}

1;
