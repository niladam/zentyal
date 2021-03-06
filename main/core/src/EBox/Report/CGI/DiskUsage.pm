# Copyright (C) 2008-2013 Zentyal S.L.
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

use strict;
use warnings;

package EBox::Report::CGI::DiskUsage;

use base 'EBox::CGI::ClientBase';

use EBox;
use EBox::Report::DiskUsage;
use EBox::FileSystem;
use EBox::Gettext;

sub new # (error=?, msg=?, cgi=?)
{
    my $class = shift;
    my $self = $class->SUPER::new('title' => __('Disk Usage'),
                      'template' => '/report/diskUsage.mas',
                      @_);
    bless($self, $class);
    return $self;
}

sub _process
{
    my $self = shift;

    my $fileSystems  = EBox::FileSystem::partitionsFileSystems();

    my $partition = $self->param('partition');
    my @partitions =   sort keys %{ $fileSystems };
    # if not partition supplied pick up the first in alphabetical order
    if (not $partition) {
      $partition = $partitions[0];
    }

    my $chartUrl       = EBox::Report::DiskUsage::chart($partition);

    my @templateParams = (
                  partition     => $partition,
                  partitionAttr => $fileSystems->{$partition},
                  chartUrl => $chartUrl,
                  partitions    => \@partitions,
                 );

    $self->{params} = \@templateParams;
}

# Method: menuFolder
#
#   Overrides <EBox::CGI::ClientBase::menuFolder>
#   to set the menu folder
sub menuFolder
{
    return 'Maintenance';
}

1;
