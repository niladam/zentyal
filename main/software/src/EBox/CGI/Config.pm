# Copyright (C) 2008-2010 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package EBox::CGI::Software::Config;

use strict;
use warnings;

use base 'EBox::CGI::ClientBase';

use EBox::Global;
use EBox::Gettext;

## arguments:
##  title [required]
sub new {
    my $class = shift;
    my $self = $class->SUPER::new('title'    =>
            __('Software management settings'),
            'template' => 'software/config.mas',
            @_);
    bless($self, $class);
    return $self;
}

sub _process($) {
    my $self = shift;
    $self->{title} = __('Automatic software updates');
    my $software = EBox::Global->modInstance('software');
    my @array = ();
    my $auto = 'no';
    if ($software->getAutomaticUpdates()) {
        $auto = 'yes';
    }
    my $QAUpdates = $software->QAUpdates();

    my $time = $software->automaticUpdatesTime();

    push(@array, 'automatic' => $auto);
    push(@array, 'automaticTime' => $time);
    push(@array, 'QAUpdates' => $QAUpdates);
    $self->{params} = \@array;
}

1;