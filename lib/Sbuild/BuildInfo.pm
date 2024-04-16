# Copyright © 2016-2022 Guillem Jover <guillem@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# forked and rewritten from https://code.launchpad.net/ubuntu/+source/dpkg

package Sbuild::BuildInfo;

use strict;
use warnings;
use Exporter qw(import);

our $VERSION = 1.00;
our @EXPORT_OK = qw(get_build_env_allowed);

my @env_allowed = (
    qw(
        CC
        CPP
        CXX
        OBJC
        OBJCXX
        PC
        FC
        M2C
        AS
        LD
        AR
        RANLIB
        MAKE
        AWK
        LEX
        YACC
    ),
    qw(
        ASFLAGS
        ASFLAGS_FOR_BUILD
        CFLAGS
        CFLAGS_FOR_BUILD
        CPPFLAGS
        CPPFLAGS_FOR_BUILD
        CXXFLAGS
        CXXFLAGS_FOR_BUILD
        OBJCFLAGS
        OBJCFLAGS_FOR_BUILD
        OBJCXXFLAGS
        OBJCXXFLAGS_FOR_BUILD
        DFLAGS
        DFLAGS_FOR_BUILD
        FFLAGS
        FFLAGS_FOR_BUILD
        LDFLAGS
        LDFLAGS_FOR_BUILD
        ARFLAGS
        MAKEFLAGS
    ),
    qw(
        LD_LIBRARY_PATH
    ),
    qw(
        LANG
        LC_ALL
        LC_CTYPE
        LC_NUMERIC
        LC_TIME
        LC_COLLATE
        LC_MONETARY
        LC_MESSAGES
        LC_PAPER
        LC_NAME
        LC_ADDRESS
        LC_TELEPHONE
        LC_MEASUREMENT
        LC_IDENTIFICATION
    ),
    qw(
        DEB_BUILD_OPTIONS
        DEB_BUILD_PROFILES
    ),
    qw(
        DEB_VENDOR
    ),
    qw(
        DPKG_ROOT
        DPKG_ADMINDIR
    ),
    qw(
        DPKG_DATADIR
    ),
    qw(
        DPKG_ORIGINS_DIR
    ),
    qw(
        DPKG_GENSYMBOLS_CHECK_LEVEL
    ),
    qw(
        SOURCE_DATE_EPOCH
    ),
);

sub get_build_env_allowed {
    return @env_allowed;
}

1;
