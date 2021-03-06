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

# Class: EBox::Firewall::Model::ExternalToInternalRuleTable
#
# This class describes the model used to store rules to access
# internal networks from external networks.
#
# Inherits from <EBox::Firewall::Model::BaseRuleTable> to fetch
# the field description
#
use strict;
use warnings;

package EBox::Firewall::Model::ExternalToInternalRuleTable;

use EBox::Global;
use EBox::Gettext;
use EBox::Validate qw(:all);
use EBox::Exceptions::External;

use EBox::Types::Text;
use EBox::Types::Union::Text;
use EBox::Types::Boolean;
use EBox::Types::Select;
use EBox::Types::InverseMatchSelect;
use EBox::Types::IPAddr;
use EBox::Types::InverseMatchUnion;
use EBox::Sudo;

use base qw(EBox::Firewall::Model::BaseRuleTable) ;

sub new
{
    my $class = shift;
    my %parms = @_;

    my $self = $class->SUPER::new(@_);
    bless($self, $class);

    return $self;
}

sub _table
{
    my ($self) = @_;

    my $dataTable =
    {
        'tableName' => 'ExternalToInternalRuleTable',
        'printableTableName' =>
          __('External networks to internal networks'),
        'automaticRemove' => 1,
        'defaultController' =>
            '/Firewall/Controller/ExternalToInternalRuleTable',
        'defaultActions' =>
            [ 'add', 'del', 'move',  'editField', 'changeView', 'clone' ],
        'tableDescription' => $self->_fieldDescription('source' => 1,
                                 'destination' => 1),
        'menuNamespace' => 'Firewall/View/ExternalToInternalRuleTable',
        'class' => 'dataTable',
        'order' => 1,
        'rowUnique' => 0,
        'printableRowName' => __('rule'),
    };

    return $dataTable;
}

1;
