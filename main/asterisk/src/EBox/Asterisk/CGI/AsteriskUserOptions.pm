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

package EBox::Asterisk::CGI::AsteriskUserOptions;

use base 'EBox::CGI::ClientBase';

use EBox::Global;
use EBox::Gettext;
use EBox::AsteriskLdapUser;
use EBox::Asterisk::Extensions;
use EBox::UsersAndGroups::User;

sub new
{
    my $class = shift;
    my $self = $class->SUPER::new('title' => 'Asterisk', @_);
    bless($self, $class);
    return $self;
}

sub _process
{
    my ($self) = @_;

    my $astldap = new EBox::AsteriskLdapUser;
    my $extensions = new EBox::Asterisk::Extensions;

    $self->_requireParam('user', __('user'));
    my $user = $self->unsafeParam('user');
    $self->{redirect} = "UsersAndGroups/User?user=$user";
    $self->keepParam('user');

    $user = new EBox::UsersAndGroups::User(dn => $user);
    if ($self->param('active') eq 'yes') {
        $astldap->setHasAccount($user, 1);
        my $myextn = $extensions->getUserExtension($user);
        my $newextn = $self->param('extension');
        if ($newextn eq '') { $newextn = $myextn; }
        if ($newextn ne $myextn) {
            $extensions->modifyUserExtension($user, $newextn);
        }
    } else {
        $astldap->setHasAccount($user, 0);
    }
}

1;
