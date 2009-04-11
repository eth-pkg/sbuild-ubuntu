#                                                              -*- Autoconf -*-
# Copyright © 2001-2002,2006-2007  Roger Leigh <rleigh@debian.org>
#
# sbuild is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# sbuild is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#####################################################################

# SBUILD_RELEASE_DATE
# --------------------
# Hard-code the release date into the generated configure script and
# Makefiles.
AC_DEFUN([SBUILD_RELEASE_DATE],
[dnl Set package release date
AC_DEFINE_UNQUOTED([RELEASE_DATE], 1239442207, [Package release date.])
RELEASE_DATE="11 Apr 2009"
AC_SUBST([RELEASE_DATE])])
