# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# Stub for the Pod::Usage module that Git for Windows' perl does not ship.
# Verilator only uses it to print --help text.
package Pod::Usage;
use Exporter 'import';
our @EXPORT = ('pod2usage');
sub pod2usage { print STDERR "verilator: invalid usage, see the Verilator manual\n"; exit 1; }
1;
