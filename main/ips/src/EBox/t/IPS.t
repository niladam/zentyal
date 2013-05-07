#!/usr/bin/perl -w
#
# Copyright (C) 2013 Zentyal S.L.
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

use warnings;
use strict;

package EBox::IPS::Test;

use base 'Test::Class';

use EBox::Global::TestStub;
use EBox::Module::Config::TestStub;
use EBox::Test::RedisMock;
use Test::Deep;
use Test::Exception;
use Test::More;

sub setUpConfiguration : Test(startup)
{
    EBox::Global::TestStub::fake();
}

sub clearConfiguration : Test(shutdown)
{
    EBox::Module::Config::TestStub::setConfig();
}

sub ips_use_ok : Test(startup => 1)
{
    use_ok('EBox::IPS') or die;
}

sub setUpInstance : Test(setup)
{
    my ($self) = @_;
    my $redis = EBox::Test::RedisMock->new();
    $self->{mod} = EBox::IPS->_create(redis => $redis);

}

sub test_isa_ok  : Test
{
    my ($self) = @_;
    isa_ok($self->{mod}, 'EBox::IPS');
}

sub test_rule_set : Test(6)
{
    my ($self) = @_;

    my $ips = $self->{mod};
    eq_deeply($ips->ASURuleSet(), []);
    lives_ok {
        $ips->setASURuleSet( [qw(aereogramme wood)]);
    } 'Setting ASU rule set';

    eq_deeply($ips->ASURuleSet(), [qw(aereogramme wood)]);
    cmp_ok($ips->usingASU(), '==', 1, 'Using ASU with this rule set');

    lives_ok {
        $ips->setASURuleSet([]);
    } 'Setting empty ASU rule set';
    cmp_ok($ips->usingASU(), '==', 0, 'Not using ASU anymore');

    lives_ok {
        $ips->setASURuleSet();
    } 'Setting undef ASU rule set';
    cmp_ok($ips->usingASU(), '==', 0, 'Not using ASU anymore with undef');
}

sub test_using_ASU : Test(5)
{
    my ($self) = @_;

    cmp_ok($self->{mod}->usingASU(), '==', 0, 'By default, not using ASU');
    lives_ok { $self->{mod}->usingASU(1) } 'Setting using ASU';
    cmp_ok($self->{mod}->usingASU(), '==', 1, 'Now using ASU');
    lives_ok { $self->{mod}->usingASU(0) } 'Unsetting using ASU';
    cmp_ok($self->{mod}->usingASU(), '==', 0, 'Not using ASU anymore');
}

1;


END {
    EBox::IPS::Test->runtests();
}
