# Copyright (C) 2009-2013 Zentyal S.L.
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

package EBox::IPS::Model::Rules;

use base 'EBox::Model::DataTable';

# Class: EBox::IPS::Model::Rules
#
#   Class description
#

use EBox::Gettext;
use EBox::Types::Boolean;
use EBox::Types::Text;
use EBox::Types::Select;

use constant DEFAULT_RULES => qw(local bad-traffic exploit community-exploit
    shellcode virus scan finger ftp telnet rpc rservices dos community-dos ddos
    dns tftp web-cgi web-misc web-client community-sql-injection community-web-client
    community-web-dos community-web-misc sql x11 icmp netbios misc attack-responses
    mysql snmp community-ftp smtp community-smtp imap community-imap pop2 pop3
    other-ids web-attacks backdoor community-bot community-virus);

# Group: Public methods

# Constructor: new
#
#       Create the new model
#
# Overrides:
#
#       <EBox::Model::DataTable::new>
#
# Returns:
#
#       <EBox::IPS::Model::Model> - the recently
#       created model
#
sub new
{
    my $class = shift;

    my $self = $class->SUPER::new(@_);

    my %default = map { $_ => 1 } DEFAULT_RULES;
    $self->{enableDefault} = \%default;

    bless ( $self, $class );

    return $self;

}

# Method: viewCustomizer
#
#      To display a permanent message
#
# Overrides:
#
#      <EBox::Model::DataTable::viewCustomizer>
#
sub viewCustomizer
{
    my ($self) = @_;

    my $customizer = $self->SUPER::viewCustomizer();

    if ( $self->parentModule()->usingASU() ) {
        my $rules = $self->parentModule()->rulesNum();
        my $msg   = $self->_commercialMsg($rules);
        $customizer->setPermanentMessage($msg);
    }

    return $customizer;
}

# Method: syncRows
#
#   Overrides <EBox::Model::DataTable::syncRows>
#
sub syncRows
{
    my ($self, $currentRows) = @_;

    my @files;
    my $usingASU = $self->parentModule()->usingASU();
    if ( $usingASU ) {
        @files = </etc/snort/rules/emerging-*.rules>;
    } else {
        @files = </etc/snort/rules/*.rules>;
    }

    my @names;
    foreach my $file (@files) {
        my $slash = rindex ($file, '/');
        my $dot = rindex ($file, '.');
        my $name = substr ($file, ($slash + 1), ($dot - $slash - 1));
        next if $name =~ /deleted/;
        push (@names, $name);
    }
    my %newNames;
    if ( $usingASU ) {
        %newNames = map { s/emerging-//; $_ => 1 } @names;
    } else {
        %newNames = map { $_ => 1 } @names;
    }

    my %currentNames =
        map { $self->row($_)->valueByName('name') => 1 } @{$currentRows};

    my $modified = 0;

    my @namesToAdd = grep { not exists $currentNames{$_} } @names;
    foreach my $name (@namesToAdd) {
        my $enabled = $self->{enableDefault}->{$name} or 0;
        $self->add(name => $name, enabled => $enabled, decision => 'log');
        $modified = 1;
    }

    # Remove old rows
    foreach my $id (@{$currentRows}) {
        my $row = $self->row($id);
        my $name = $row->valueByName('name');
        if (not exists $newNames{$name} or ($name =~ /deleted/)) {
            $self->removeRow($id);
            $modified = 1;
        }
    }

    return $modified;
}

# Method: headTitle
#
#   Overrides <EBox::Model::DataTable::headTitle>
#
sub headTitle
{
    return undef;
}

# Group: Protected methods

# Method: _table
#
#       Model description
#
# Overrides:
#
#      <EBox::Model::DataTable::_table>
#
sub _table
{
    my @tableHeader = (
        new EBox::Types::Text(
            'fieldName' => 'name',
            'printableName' => __('Rule Set'),
            'unique' => 1,
            'editable' => 0),
        new EBox::Types::Boolean (
            'fieldName' => 'enabled',
            'printableName' => __('Enabled'),
            'defaultValue' => 0,
            'editable' => 1
        ),
        new EBox::Types::Select (
            'fieldName' => 'decision',
            'printableName' => __('Action'),
            'populate' => \&_populateActions,
            'editable' => 1
        ),
    );

    my $dataTable =
    {
        tableName          => 'Rules',
        printableTableName => __('Rules'),
        defaultActions     => [ 'editField', 'changeView' ],
        tableDescription   => \@tableHeader,
        class              => 'dataTable',
        modelDomain        => 'IPS',
        printableRowName   => __('rule'),
        help               => __('Select the sets of rules you want apply when scanning the network traffic'),
    };
    return $dataTable;
}

# Group: Private methods

sub _populateActions
{
    return [
        { value => 'log', printableValue => __('Log') },
        { value => 'block', printableValue => __('Block') },
        { value => 'logblock', printableValue => __('Log & Block') },
    ];
}

sub _commercialMsg
{
    my ($self, $rulesNum) = @_;

    return __sx('Advanced Security Updates grants you to use daily updated {rules} rules',
                rules => $rulesNum);

}

1;
