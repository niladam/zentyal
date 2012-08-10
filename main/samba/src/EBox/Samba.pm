# Copyright (C) 2012 eBox Technologies S.L.
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

package EBox::Samba;

use strict;
use warnings;

use base qw(EBox::Module::Service EBox::FirewallObserver EBox::LdapModule EBox::LogObserver);

use EBox::Global;
use EBox::Service;
use EBox::Sudo;
use EBox::SambaLdapUser;
use EBox::Network;
use EBox::SambaFirewall;
use EBox::SambaLogHelper;
use EBox::Dashboard::Widget;
use EBox::Dashboard::List;
use EBox::Menu::Item;
use EBox::Exceptions::Internal;
use EBox::Gettext;
use EBox::Config;
use EBox::DBEngineFactory;
use EBox::LDB;
use EBox::Util::Random qw( generate );

use Perl6::Junction qw( any );
use Net::Domain qw(hostdomain);
use Error qw(:try);
use File::Slurp;

use constant SAMBATOOL            => '/usr/bin/samba-tool';
use constant SAMBAPROVISION       => '/usr/share/samba/setup/provision';
use constant SAMBACONFFILE        => '/etc/samba/smb.conf';
use constant PRIVATE_DIR          => '/var/lib/samba/private/';
use constant SAMBA_DIR            => '/home/ebox/samba';
use constant SAMBADNSZONE         => PRIVATE_DIR . 'named.conf';
use constant SAMBA_DNS_POLICY     => PRIVATE_DIR . 'named.conf.update';
use constant SAMBADNSKEYTAB       => PRIVATE_DIR . 'dns.keytab';
use constant SAM_DB               => PRIVATE_DIR . 'sam.ldb';
use constant SAMBADNSAPPARMOR     => '/etc/apparmor.d/local/usr.sbin.named';
use constant FSTAB_FILE           => '/etc/fstab';
use constant SYSVOL_DIR           => '/var/lib/samba/sysvol';
use constant SHARES_DIR           => SAMBA_DIR . '/shares';
use constant PROFILES_DIR         => SAMBA_DIR . '/profiles';
use constant LOGON_SCRIPT         => 'logon.bat';
use constant LOGON_DEFAULT_SCRIPT => 'zentyal-logon.bat';

use constant CLAMAVSMBCONFFILE    => '/etc/samba/vscan-clamav.conf';

sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(
        name => 'samba',
        printableName => __('File Sharing'),
        @_);
    bless ($self, $class);
    return $self;
}

# Method: bootDepends
#
#   Samba depends on CUPS only if printers module enabled.
#
# Overrides:
#
#   <EBox::Module::Base::depends>
#
sub bootDepends
{
    my ($self) = @_;

    my $dependsList = $self->depends();

    my $module = 'printers';
    if (EBox::Global->modExists($module)) {
        my $printers = EBox::Global->modInstance($module);
        if ($printers->isEnabled()) {
            push (@{$dependsList}, $module);
        }
    }

    return $dependsList;
}

# Method: actions
#
#   Override EBox::Module::Service::actions
#
sub actions
{
    return [
        {
            'action' => __('Create Samba home directory for shares and groups'),
            'reason' => __('Zentyal will create the directories for Samba ' .
                           'shares and groups under /home/ebox/samba.'),
            'module' => 'samba',
        },
    ];
}

# Method: usedFiles
#
#   Override EBox::Module::Service::files
#
sub usedFiles
{
    return [
        {
            'file'   => SAMBACONFFILE,
            'reason' => __('To set up Samba according to your configuration.'),
            'module' => 'samba',
        },
        {
            'file'   => FSTAB_FILE,
            'reason' => __('To enable extended attributes and acls.'),
            'module' => 'samba',
        },
        {
            'file'   => '/etc/services',
            'reason' => __('To add microsoft specific services'),
            'module' => 'samba',
        },
        {
            'file' => CLAMAVSMBCONFFILE,
            'reason' => __('To set the antivirus settings for Samba.'),
            'module' => 'samba'
        },
    ];
}

# Method: initialSetup
#
# Overrides:
#
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    # Create default rules and services only if enabling the first time
    unless ($version) {
        my $services = EBox::Global->modInstance('services');

        my $serviceName = 'samba';
        unless($services->serviceExists(name => $serviceName)) {
            $services->addMultipleService(
                'name' => $serviceName,
                'printableName' => 'Samba',
                'description' => __('File sharing (Samba) protocol'),
                'internal' => 1,
                'readOnly' => 1,
                'services' => $self->_services(),
            );
        }

        my $firewall = EBox::Global->modInstance('firewall');
        $firewall->setInternalService($serviceName, 'accept');
        $firewall->saveConfigRecursive();
    }
}

sub _services
{
    my ($self) = @_;

    return [
            { # kerberos
                'protocol' => 'tcp/udp',
                'sourcePort' => 'any',
                'destinationPort' => '88',
                'description' => 'Kerberos authentication',
            },
            { # DCE endpoint resolution
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '135',
                'description' => 'DCE endpoint resolution',
            },
            { # netbios-ns
                'protocol' => 'udp',
                'sourcePort' => 'any',
                'destinationPort' => '137',
                'description' => 'NETBIOS name service',
            },
            { # netbios-dgm
                'protocol' => 'udp',
                'sourcePort' => 'any',
                'destinationPort' => '138',
                'description' => 'NETBIOS datagram service',
            },
            { # netbios-ssn
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '139',
                'description' => 'NETBIOS session service',
            },
            { # samba LDAP
                'protocol' => 'tcp/udp',
                'sourcePort' => 'any',
                'destinationPort' => '389',
                'description' => 'Lightweight Directory Access Protocol',
            },
            { # microsoft-ds
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '445',
                'description' => 'Microsoft directory services',
            },
            { # kerberos change/set password
                'protocol' => 'tcp/udp',
                'sourcePort' => 'any',
                'destinationPort' => '464',
                'description' => 'Kerberos set/change password',
            },
            { # LDAP over TLS/SSL
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '636',
                'description' => 'LDAP over TLS/SSL',
            },
            { # unknown???
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '1024',
            },
            { # msft-gc
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '3268',
                'description' => 'Microsoft global catalog',
            },
            { # msft-gc-ssl
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '3269',
                'description' => 'Microsoft global catalog over SSL',
            },
        ];
}

# Method: enableActions
#
#   Override EBox::Module::Service::enableActions
#
sub enableActions
{
    my ($self) = @_;

    my @cmds = ();
    push (@cmds, 'mkdir -p ' . SAMBA_DIR);
    push (@cmds, 'mkdir -p ' . PROFILES_DIR);
    EBox::debug('Creating directories');
    EBox::Sudo::root(@cmds);

    # Remount filesystem with user_xattr and acl options
    EBox::debug('Setting up filesystem options');
    EBox::Sudo::root(EBox::Config::scripts('samba') . 'setup-filesystem');

    # Add 'Global catalog' service to /etc/services
    my $dnsMod = EBox::Global->modInstance('dns');
    my $srvModel = $dnsMod->model('Services');
    my $services = $srvModel->services();
    my %aux = map { $_->{name} => 1 } @{$services};
    unless (exists $aux{gc}) {
        push (@{$services}, { name => 'gc', port => 3268, protocol => 'tcp' });
        EBox::debug('Adding Microsoft global catalog service to /etc/services');
        my $cmd = "echo 'gc\t\t3268/tcp\t\t\t# Microsoft Global Catalog' >> /etc/services";
        EBox::Sudo::root($cmd);
    }
}

sub isProvisioned
{
    my $samba = EBox::Global->modInstance('samba');
    my $isProvisioned = $samba->get_bool('provisioned');
    EBox::debug("Samba provisioned flag: $isProvisioned");
    return $isProvisioned;
}

# Method: enableService
#
#   Override EBox::Module::Service::enableService to
#   set DNS and users modules as changed
#
sub enableService
{
    my ($self, $status) = @_;

    $self->SUPER::enableService($status);
    if ($self->changed() and $status) {
        my $isProvisioned = isProvisioned();
        unless ($isProvisioned == 1) {
            try {
                $self->provision();
            } otherwise {
                my $error = shift;
                EBox::error($error);

                # Disable the module if not provisioned
                $self->SUPER::enableService(0);

                throw $error;
            };
        }
    }
    my $modules = EBox::Global->modInstancesOfType('EBox::KerberosModule');
    foreach my $module (@{$modules}) {
        $module->kerberosCreatePrincipals();
    }

    if ($self->changed()) {
        EBox::Global->modChange('dns');
        EBox::Global->modChange('users');
    }
}

# Method: shares
#
#   It returns the custom shares
#
# Parameters:
#
#     all - return all shares regardless of their permission
#           level. Otherwise shares without permssions or guset access are
#           ignored. Default: false
#
# Returns:
#
#   Array ref containing hash ref with:
#
#   share   - share's name
#   path    - share's path
#   comment - share's comment
#   readOnly  - string containing users and groups with read-only permissions
#   readWrite - string containing users and groups with read and write
#               permissions
#   administrators  - string containing users and groups with admin priviliges
#                     on the share
#   validUsers - readOnly + readWrite + administrators
#
sub shares
{
    my ($self, $all) = @_;

    my $shares = $self->model('SambaShares');
    my @shares = ();

    for my $id (@{$shares->enabledRows()}) {
        my $row = $shares->row($id);
        my @readOnly;
        my @readWrite;
        my @administrators;
        my $shareConf = {};

        my $path = $row->elementByName('path');
        if ($path->selectedType() eq 'zentyal') {
            $shareConf->{'path'} = SHARES_DIR . '/' . $path->value();
        } else {
            $shareConf->{'path'} = $path->value();
        }
        $shareConf->{'share'} = $row->valueByName('share');
        $shareConf->{'comment'} = $row->valueByName('comment');
        $shareConf->{'guest'} = $row->valueByName('guest');
        $shareConf->{'groupShare'} = $row->valueByName('groupShare');

        for my $subId (@{$row->subModel('access')->ids()}) {
            my $subRow = $row->subModel('access')->row($subId);
            my $userType = $subRow->elementByName('user_group');
            my $preCar = '';
            if ($userType->selectedType() eq 'group') {
                $preCar = '@';
            }
            my $user =  $preCar . '"' . $userType->printableValue() . '"';

            my $permissions = $subRow->elementByName('permissions');

            if ($permissions->value() eq 'readOnly') {
                push (@readOnly, $user);
            } elsif ($permissions->value() eq 'readWrite') {
                push (@readWrite, $user);
            } elsif ($permissions->value() eq 'administrator') {
                push (@administrators, $user)
            }
        }

        if (not $all) {
            next unless (@readOnly or @readWrite or @administrators
                         or $shareConf->{'guest'});
        }

        $shareConf->{'readOnly'} = join (', ', @readOnly);
        $shareConf->{'readWrite'} = join (', ', @readWrite);
        $shareConf->{'administrators'} = join (', ', @administrators);
        $shareConf->{'validUsers'} = join (', ', @readOnly,
                                                 @readWrite,
                                                 @administrators);

        push (@shares, $shareConf);
    }

    return \@shares;
}

sub defaultAntivirusSettings
{
    my ($self) = @_;

    my $antivirus = $self->model('AntivirusDefault');
    return $antivirus->row()->valueByName('scan');
}

sub antivirusExceptions
{
    my ($self) = @_;

    my $model = $self->model('AntivirusExceptions');
    my $exceptions = {
        'share' => {},
        'group' => {},
    };

    foreach my $id (@{$model->ids()}) {
        my $row = $model->row($id);
        my $element = $row->elementByName('user_group_share');
        my $type = $element->selectedType();
        if ($type eq 'users') {
            $exceptions->{'users'} = 1;
        } else {
            my $value = $element->printableValue();
            $exceptions->{$type}->{$value} = 1;
        }
    }

    return $exceptions;
}

sub defaultRecycleSettings
{
    my ($self) = @_;

    my $recycle = $self->model('RecycleDefault');
    return $recycle->row()->valueByName('enabled');
}

sub recycleExceptions
{
    my ($self) = @_;

    my $model = $self->model('RecycleExceptions');
    my $exceptions = {
        'share' => {},
        'group' => {},
    };

    for my $id (@{$model->ids()}) {
        my $row = $model->row($id);
        my $element = $row->elementByName('user_group_share');
        my $type = $element->selectedType();
        if ($type eq 'users') {
            $exceptions->{'users'} = 1;
        } else {
            my $value = $element->printableValue();
            $exceptions->{$type}->{$value} = 1;
        }
    }
    return $exceptions;
}

sub recycleConfig
{
    my ($self) = @_;

    my $conf = {};
    my @keys = ('repository', 'directory_mode', 'keeptree', 'versions', 'touch', 'minsize',
                'maxsize', 'exclude', 'excludedir', 'noversions');

    foreach my $key (@keys) {
        my $value = EBox::Config::configkey($key);
        if ($value) {
            $conf->{$key} = $value;
        }
    }

    return $conf;
}

sub cleanDNS
{
    my ($self, $domain) = @_;

    my $dnsMod = EBox::Global->modInstance('dns');
    my @records = (
        {
            type => 'host',
            name => 'gc',
            subdomain => '_msdcs'
        },
        {
            type      => 'service',
            service   => 'gc',
            protocol  => 'tcp',
            subdomain => undef,
            port      => 3268
        },
        {
            type      => 'service',
            service   => 'gc',
            protocol  => 'tcp',
            subdomain => 'Default-First-Site-Name._sites',
            port      => 3268
        },
        {
            type      => 'service',
            service   => 'ldap',
            protocol  => 'tcp',
            subdomain => 'gc._msdcs',
            port      => 3268
        },
        {
            type      => 'service',
            service   => 'ldap',
            protocol  => 'tcp',
            subdomain => 'Default-First-Site-Name._sites.gc._msdcs',
            port      => 3268
        },
        {
            type      => 'service',
            service   => 'ldap',
            protocol  => 'tcp',
            subdomain => undef,
            port      => 389
        },
        {
            type      => 'service',
            service   => 'ldap',
            protocol  => 'tcp',
            subdomain => 'pdc._msdcs',
            port      => '389',
        },
        {
            type      => 'service',
            service   => 'ldap',
            subdomain => '.+\.domains._msdcs',
            protocol  => 'tcp',
            port      => 389
        },
        {
            type      => 'service',
            service   => 'ldap',
            protocol  => 'tcp',
            subdomain => 'Default-First-Site-Name._sites.dc._msdcs',
            port      => 389
        },
        {
            type      => 'service',
            service   => 'ldap',
            protocol  => 'tcp',
            subdomain => 'Default-First-Site-Name._sites',
            port      => 389
        },
        {
            type      => 'service',
            service   => 'ldap',
            protocol  => 'tcp',
            subdomain => 'dc._msdcs',
            port      => 389
        },
        {
            type      => 'service',
            service   => 'kerberos',
            protocol  => 'tcp',
            subdomain => 'dc._msdcs',
            port      => 88
        },
        {
            type      => 'service',
            service   => 'kerberos',
            protocol  => 'tcp',
            subdomain => 'Default-First-Site-Name._sites',
            port      => 88
        },
        {
            type      => 'service',
            service   => 'kerberos',
            protocol  => 'tcp',
            subdomain => 'Default-First-Site-Name._sites.dc._msdcs',
            port      => 88
        },
    );

    foreach my $record (@records) {
        try {
            if ($record->{type} eq 'host') {
                $dnsMod->delHost($domain, $record->{name});
            } elsif ($record->{type} eq 'service') {
                $dnsMod->delService($domain, $record);
            }
        } otherwise {
            my $error = shift;
            EBox::debug($error);
        };
    }

    # Remove serverGUID._mdscs alias
    my $hosts = $dnsMod->getHostnames($domain);
    foreach my $host (@{$hosts}) {
        my $aliases = $host->{aliases};
        foreach my $alias (@{$aliases}) {
            if ($alias =~ m/.+\._msdcs$/) {
                try {
                    $dnsMod->removeAlias($domain, $host->{name}, $alias);
                } otherwise {
                    my $error = shift;
                    EBox::error($error);
                };
            }
        }
    }
}

# Method: provision
#
#   This method provision the database
#
sub provision
{
    my ($self) = @_;

    # Check that there are internal IP addresses configured
    my $network = EBox::Global->modInstance('network');
    my $ipaddrs = $network->internalIpAddresses();
    unless (scalar @{$ipaddrs} > 0) {
        throw EBox::Exceptions::External(__('There are not any interanl IP address configured, ' .
                                            'cannot continue with database provision. The module ' .
                                            'will remain disabled.'));
    }

    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $users   = EBox::Global->modInstance('users');
    my $hostName   = $sysinfo->hostName();
    my $domainName = $sysinfo->hostDomain();
    my $realm      = uc ($domainName); # TODO Create a function realm() in sysinfo

    # Remove previous DNS records
    $self->cleanDNS($domainName);

    # This file must be deleted or provision may fail
    my $fs = EBox::Config::configkey('samba_fs');
    EBox::Sudo::root('rm -f ' . SAMBACONFFILE);
    my $cmd = SAMBAPROVISION .
        ' --domain=' . $self->workgroup() .
        ' --workgroup=' . $self->workgroup() .
        ' --realm=' . $realm .
        ' --dns-backend=BIND9_FLATFILE' .
        ' --use-xattrs=yes ' .
        ' --server-role=' . $self->mode() .
        ' --users=' . $users->DEFAULTGROUP() .
        ' --host-name=' . $sysinfo->hostName();
    $cmd .= ' --use-ntvfs' if (defined $fs and $fs eq 'ntvfs');

    EBox::debug("Provisioning database '$cmd'");

    $cmd .= " --adminpass='" . $self->administratorPassword() . "'";

    # Use silent root to avoid showing the admin pass in the logs if
    # provision command fails.
    my $output = EBox::Sudo::silentRoot($cmd);
    if ($? == 0) {
        EBox::debug("Provision result: @{$output}");
        # Mark the module as provisioned
        EBox::debug('Setting provisioned flag');
        $self->set_bool('provisioned', 1);
    } else {
        my @error = ();
        my $stderr = EBox::Config::tmp() . 'stderr';
        if (-r $stderr) {
            @error = read_file($stderr);
        }
        throw EBox::Exceptions::Internal("Error provisioning database. Output: @{$output}, error:@error");
    };

    # The administrator password is also the password for the 'Zentyal' user,
    # save it to a file to connect LDB
    $self->_savePassword($self->administratorPassword(),
                         EBox::Config->conf() . "ldb.passwd");

    # Once provisioned start the service to make queries
    EBox::debug('Starting service');
    $self->_manageService('start');

    # Add the DNS records
    EBox::debug('Adding domain DNS records');
    my $dnsMod  = EBox::Global->modInstance('dns');

    # Get the domain GUID
    my $args = { base   => $self->ldb->dn(),
                 scope  => 'base',
                 filter => '(objectClass=*)',
                 attrs  => ['objectGUID'] };
    my $result = $self->ldb->search($args);
    my $entry = $result->entry(0);
    my $domainGUID = $entry->get_value('objectGUID');
    $domainGUID = $self->ldb->guidToString($domainGUID);
    EBox::debug("Domain GUID: $domainGUID"); # TODO remove

    # Get the server GUID
    $args = { base => "CN=NTDS Settings," .
                      "CN=" . uc ($hostName) . "," .
                      "CN=Servers," .
                      "CN=Default-First-Site-Name," .
                      "CN=Sites," .
                      "CN=Configuration," .
                      $self->ldb->dn(),
              scope  => 'base',
              filter => '(objectClass=*)',
              attrs  => ['objectGUID'] };
    $result = $self->ldb->search($args);
    $entry = $result->entry(0);
    my $serverGUID = $entry->get_value('objectGUID');
    $serverGUID = $self->ldb->guidToString($serverGUID);
    EBox::debug("Server GUID: $serverGUID"); # TODO remove

    my $host = { name => 'gc',
                 subdomain => '_msdcs',
                 ipAddresses => $ipaddrs };
    $dnsMod->addHost($domainName, $host);

    my $alias = "$serverGUID._msdcs";
    $dnsMod->addAlias($domainName, $hostName, $alias);

    my $service = { service => 'gc',
                    protocol => 'tcp',
                    port => 3268,
                    priority => 0,
                    weight => 100,
                    target_type => 'domainHost',
                    target => $hostName };
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = 'Default-First-Site-Name._sites';
    $dnsMod->addService($domainName, $service);

    $service->{service} = 'ldap';
    $service->{subdomain} = 'gc._msdcs';
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = 'Default-First-Site-Name._sites.gc._msdcs';
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = undef;
    $service->{port} = 389;
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = 'dc._msdcs';
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = 'pdc._msdcs';
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = "$domainGUID.domains._msdcs";
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = 'Default-First-Site-Name._sites';
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = 'Default-First-Site-Name._sites.dc._msdcs';
    $dnsMod->addService($domainName, $service);

    $service->{service} = 'kerberos';
    $service->{port} = 88;
    $service->{subdomain} = 'dc._msdcs';
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = 'Default-First-Site-Name._sites';
    $dnsMod->addService($domainName, $service);

    $service->{subdomain} = 'Default-First-Site-Name._sites.dc._msdcs';
    $dnsMod->addService($domainName, $service);

    # Set the domain as dynamic. Otherwise apparmor deny the updates.
    $dnsMod->setDynamic($domainName, 1);

    # Disable password policy
    # NOTE complexity is disabled because when changing password in
    #      zentyal the command may fail if it do not meet requirements,
    #      ending with different passwords
    EBox::debug('Setting password policy');
    $cmd = SAMBATOOL . " domain passwordsettings set " .
                       " --complexity=off "  .
                       " --min-pwd-length=0" .
                       " --min-pwd-age=0" .
                       " --max-pwd-age=365";
    EBox::Sudo::root($cmd);

    # Load all zentyal users and groups into ldb
    $self->ldb->ldapUsersToLdb();
    $self->ldb->ldapGroupsToLdb();

    # Add the zentyal module to the LDB modules stack
    my $ldif = "dn: \@MODULES\n" .
               "changetype: modify\n" .
               "replace: \@LIST\n" .
               "\@LIST: zentyal,samba_dsdb\n";
    EBox::Sudo::root("echo '$ldif' | ldbmodify -H " . SAM_DB);

}

# Method: sambaInterfaces
#
#   Return interfaces upon samba should listen
#
sub sambaInterfaces
{
    my ($self) = @_;

    my @ifaces = ();
    # Always listen on loopback interface
    push (@ifaces, 'lo');

    my $net = EBox::Global->modInstance('network');

    my $listen_external = EBox::Config::configkey('listen_external');

    my $netIfaces;
    if ($listen_external eq 'yes') {
        $netIfaces = $net->allIfaces();
    } else {
        $netIfaces = $net->InternalIfaces();
    }

    foreach my $iface (@{$netIfaces}) {
        push @ifaces, $iface;

        if ($net->ifaceMethod($iface) eq 'bridged') {
            my $br = $net->ifaceBridge($iface);
            push (@ifaces, "br$br");
            next;
        }

        my $vifacesNames = $net->vifaceNames($iface);
        if (defined $vifacesNames) {
            push @ifaces, @{$vifacesNames};
        }
    }

    my @moduleGeneratedIfaces = ();
    push @ifaces, @moduleGeneratedIfaces;
    return \@ifaces;
}

sub _setConf
{
    my ($self) = @_;

    return unless $self->configured() and $self->isEnabled();

    $self->provision() unless $self->isProvisioned();

    my $interfaces = join (',', @{$self->sambaInterfaces()});

    my $netbiosName = $self->netbiosName();
    my $realmName   = $self->realm();

    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    my @array = ();
    push (@array, 'fs'          => EBox::Config::configkey('samba_fs'));
    push (@array, 'prefix'      => $prefix);
    push (@array, 'workgroup'   => $self->workgroup());
    push (@array, 'netbiosName' => $netbiosName);
    push (@array, 'description' => $self->description());
    push (@array, 'ifaces'      => $interfaces);
    push (@array, 'mode'        => $self->mode());
    push (@array, 'realm'       => $realmName);
    push (@array, 'roamingProfiles' => $self->roamingProfiles());

    push (@array, 'printers'  => $self->printersConf());

    #push(@array, 'backup_path' => EBox::Config::conf() . 'backups');
    #push(@array, 'quarantine_path' => EBox::Config::var() . 'lib/zentyal/quarantine');

    my $shares = $self->shares();
    push(@array, 'shares' => $shares);

    push (@array, 'antivirus' => $self->defaultAntivirusSettings());
    push (@array, 'antivirus_exceptions' => $self->antivirusExceptions());
    push (@array, 'recycle' => $self->defaultRecycleSettings());
    push (@array, 'recycle_exceptions' => $self->recycleExceptions());
    push (@array, 'recycle_config' => $self->recycleConfig());

    #my $netlogonDir = "/var/lib/samba/sysvol/" . $self->realm() . "/scripts";
    #if ($self->mode() eq 'dc') {
    #    #my $logonScript = join('/', $netlogonDir, LOGON_SCRIPT);
    #    #if (EBox::Sudo::fileTest('-f', $logonScript)) {
    #    #    push(@array, 'logon_script', LOGON_SCRIPT);
    #    #}
    #    $self->writeConfFile(join('/', $netlogonDir, LOGON_DEFAULT_SCRIPT),
    #        'samba/logon.bat.mas', \@array);
    #}

    $self->writeConfFile(SAMBACONFFILE,
                         'samba/smb.conf.mas', \@array);

    $self->writeConfFile(CLAMAVSMBCONFFILE,
                         'samba/vscan-clamav.conf.mas', []);

    # Remove shares
    $self->model('SambaDeletedShares')->removeDirs();
    # Create shares
    $self->model('SambaShares')->createDirs();

    # Change group ownership of quarantine_dir to __USERS__
    my $quarantine_dir = EBox::Config::var() . '/lib/zentyal/quarantine';
    EBox::Sudo::silentRoot("chown root:__USERS__ $quarantine_dir");

    # Set roaming profiles
    if ($self->roamingProfiles()) {
        my $path = "\\\\$netbiosName.$realmName\\profiles";
        $self->ldb()->setRoamingProfiles(1, $path);
    } else {
        $self->ldb()->setRoamingProfiles(0);
    }

    # Mount user home on network drive
    $self->ldb()->setHomeDrive($self->drive());
}

sub printersConf
{
    my ($self) = @_;

    my $printers = [];
    if (EBox::Global->modExists('printers')) {
        my $printersModule = EBox::Global->modInstance('printers');
        if ($printersModule->isEnabled()) {
            my $printersModel = $printersModule->model('Printers');
            my $ids = $printersModel->ids();
            foreach my $id (@{$ids}) {
                my $row = $printersModel->row($id);
                my $printerName = $row->valueByName('printer');
                my $printerGuest = $row->valueByName('guest');
                my $printerDescription = $row->valueByName('description');
                # Get the allowed users and groups for this printer if guest
                # access is disabled
                my $printerAcl = [];
                for my $subId (@{$row->subModel('access')->ids()}) {
                    my $subRow = $row->subModel('access')->row($subId);
                    my $userType = $subRow->elementByName('user_group');
                    my $preCar = $userType->selectedType() eq 'group' ? '@' : '';
                    my $user =  $preCar . '"' . $userType->printableValue() . '"';
                    push (@{$printerAcl}, $user);
                }
                push (@{$printers}, {
                    name => $printerName,
                    description => $printerDescription,
                    guest => $printerGuest,
                    acl => $printerAcl,
                } );
            }
        }
    }

    return $printers;
}

sub _shareUsers
{
    my $state = 0;
    my $pids = {};

#    for my $line (`smbstatus`) {
#        chomp($line);
#        if($state == 0) {
#            if($line =~ '----------------------------') {
#                $state = 1;
#            }
#        } elsif($state == 1) {
#            if($line eq '') {
#                $state = 2;
#            } else {
#                # 1735  javi   javi     blackops  (192.168.45.48)
#                $line =~ m/(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\((\S+)\)/;
#                my ($pid, $user, $machine) = ($1, $2, $4);
#                $pids->{$pid} = { 'user' => $user, 'machine' => $machine };
#            }
#        } elsif($state == 2) {
#            if($line =~ '----------------------------') {
#                $state = 3;
#            }
#        } elsif($state == 3) {
#            if($line eq '') {
#                last;
#            } else {
#            #administracion   1735   blackops      Wed Nov 26 17:27:19 2008
#                $line =~ m/(\S+)\s+(\d+)\s+(\S+)\s+(\S.+)/;
#                my($share, $pid, $date) = ($1, $2, $4);
#                $pids->{$pid}->{'share'} = $share;
#                $pids->{$pid}->{'date'} = $date;
#            }
#        }
#    }
    return [values %{$pids}];
}

sub _sharesGroupedBy
{
    my ($group) = @_;

    my $shareUsers = _shareUsers();

    my $groupedInfo = {};
    foreach my $info (@{$shareUsers}) {
        if (not defined ($groupedInfo->{$info->{$group}})) {
            $groupedInfo->{$info->{$group}} = [];
        }
        push (@{$groupedInfo->{$info->{$group}}}, $info);
    }
    return $groupedInfo;
}

sub sharesByUserWidget
{
    my ($widget) = @_;

    my $sharesByUser = _sharesGroupedBy('user');

    foreach my $user (sort keys %{$sharesByUser}) {
        my $section = new EBox::Dashboard::Section($user, $user);
        $widget->add($section);
        my $titles = [__('Share'), __('Source machine'), __('Connected since')];

        my $rows = {};
        foreach my $share (@{$sharesByUser->{$user}}) {
            my $id = $share->{'share'} . '_' . $share->{'machine'};
            $rows->{$id} = [$share->{'share'}, $share->{'machine'}, $share->{'date'}];
        }
        my $ids = [sort keys %{$rows}];
        $section->add(new EBox::Dashboard::List(undef, $titles, $ids, $rows));
    }
}

sub usersByShareWidget
{
    my ($widget) = @_;

    my $usersByShare = _sharesGroupedBy('share');

    for my $share (sort keys %{$usersByShare}) {
        my $section = new EBox::Dashboard::Section($share, $share);
        $widget->add($section);
        my $titles = [__('User'), __('Source machine'), __('Connected since')];

        my $rows = {};
        foreach my $user (@{$usersByShare->{$share}}) {
            my $id = $user->{'user'} . '_' . $user->{'machine'};
            $rows->{$id} = [$user->{'user'}, $user->{'machine'}, $user->{'date'}];
        }
        my $ids = [sort keys %{$rows}];
        $section->add(new EBox::Dashboard::List(undef, $titles, $ids, $rows));
    }
}

# Method: widgets
#
#   Override EBox::Module::widgets
#
sub widgets
{
    return {
        'sharesbyuser' => {
            'title' => __('Shares by user'),
            'widget' => \&sharesByUserWidget,
            'order' => 7,
            'default' => 1
        },
        'usersbyshare' => {
            'title' => __('Users by share'),
            'widget' => \&usersByShareWidget,
            'order' => 9,
            'default' => 1
        }
    };
}

# Method: _daemons
#
#       Override EBox::Module::Service::_daemons
#
sub _daemons
{
    return [
        {
            name => 'samba4',
            precondition => \&isProvisioned,
            pidfiles => ['/var/run/samba.pid'],
        },
        {
            name => 'zentyal.s4sync',
            precondition => \&isProvisioned,
        },
    ];
}

# Function: usesPort
#
#   Implements EBox::FirewallObserver interface
#
sub usesPort
{
    my ($self, $protocol, $port, $iface) = @_;

    return undef unless($self->isEnabled());

    foreach my $smbport (@{$self->_services()}) {
        return 1 if ($port eq $smbport->{destinationPort});
    }

    return undef;
}

sub firewallHelper
{
    my ($self) = @_;

    if ($self->isEnabled()) {
        return new EBox::SambaFirewall();
    }
    return undef;
}

# Method: firewallCaptivePortalExceptions
#
#  this method gives firewall ruels to add to the captive portal module.
#  They purpose is to allow domain joins without captive portal interference
sub firewallCaptivePortalExceptions
{
    my ($self) = @_;
    my @rules;

    if (not $self->isEnabled()) {
       return [];
    }

     my @services = @{ $self->_services() };
    foreach my $conf (@services) {
        my $args = '';
        my $tcpAndUdp = 0;
        if ($conf->{protocol} ne 'any') {
            if ($conf->{protocol} eq 'tcp/udp') {
                $tcpAndUdp = 1;
            } else {
                $args .= '--protocol ' . $conf->{protocol};
            }
        }
        if ($conf->{sourcePort} ne 'any') {
            $args .= ' --sport ' . $conf->{sourcePort};
        }
        if ($conf->{destinationPort} ne 'any') {
            $args .= ' --dport ' . $conf->{destinationPort};
        }

        if ($args) {
            if ($tcpAndUdp) {
                push @rules, "--protocol tcp $args -j RETURN";
                push @rules, "--protocol udp $args -j RETURN";
            } else {
                push @rules, "$args -j RETURN";
            }
        }
    }

    return \@rules;
}


sub menu
{
    my ($self, $root) = @_;

    $root->add(new EBox::Menu::Item('url' => 'Samba/Composite/General',
                                    'text' => $self->printableName(),
                                    'separator' => 'Office',
                                    'order' => 540));
}

# Method: defaultAdministratorPassword
#
#   Generates a default administrator password
#
sub defaultAdministratorPassword
{
    return 'Zentyal1234';
}

# Method: administratorPassword
#
#   Returns the administrator password
sub administratorPassword
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->passwordValue();
}

# Method: defaultNetbios
#
#   Generates the default netbios server name
#
sub defaultNetbios
{
    my ($self) = @_;

    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $hostName = $sysinfo->hostName();

    return $hostName;
}

# Method: netbiosName
#
#   Returns the configured netbios name
#
sub netbiosName
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->netbiosNameValue();
}

# Method: defaultRealm
#
#   Generates the default realm
#
sub defaultRealm
{
    my ($self) = @_;

    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $domainName = $sysinfo->hostDomain();

    return $domainName;
}

# Method: realm
#
#   Returns the configured realm
#
sub realm
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->realmValue();
}

# Method: defaultWorkgroup
#
#   Generates the default workgroup
#
sub defaultWorkgroup
{
    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    return uc($prefix) . '-DOMAIN';
}

# Method: workgroup
#
#   Returns the configured workgroup name
#
sub workgroup
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->workgroupValue();
}

# Method: defaultDescription
#
#   Generates the default server string
#
sub defaultDescription
{
    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    return ucfirst($prefix) . ' File Server';
}

# Method: description
#
#   Returns the configured description string
#
sub description
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->descriptionValue();
}

# Method: roamingProfiles
#
#   Returns if roaming profiles are enabled
#
sub roamingProfiles
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->roamingValue();
}

# Method: mode
#
#   Returns the configured server mode
#
sub mode
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->modeValue();
}

# Method: drive
#
#   Returns the configured drive letter
#
sub drive
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->driveValue();
}

# Method: _ldapModImplementation
#
#   LdapModule implmentation
#
sub _ldapModImplementation
{
    my $self;

    return new EBox::SambaLdapUser();
}

sub restoreConfig
{
    my ($self, $dir) = @_;

#    try {
#       TODO: Provision database and export LDAP to LDB
#        my $sambaLdapUser = new EBox::SambaLdapUser;
#        $sambaLdapUser->migrateUsers();
#    } otherwise {
#    } finally {
#    };
}

sub restoreDependencies
{
    my @depends = ();

    push (@depends, 'users');

    if (EBox::Global->modExists('printers')) {
        push (@depends, 'printers');
    }

    return \@depends;
}


# backup domains

#sub backupDomains
#{
#    my $name = 'shares';
#    my %attrs  = (
#                  printableName => __('File Sharing'),
#                  description   => __(q{Shares, users and groups homes and profiles}),
#                 );
#
#    return ($name, \%attrs);
#}

#sub backupDomainsFileSelection
#{
#    my ($self, %enabled) = @_;
#    if ($enabled{shares}) {
#        my $sambaLdapUser = new EBox::SambaLdapUser();
#        my @dirs = @{ $sambaLdapUser->sharedDirectories() };
#        push @dirs, map {
#            $_->{path}
#        } @{ $self->shares(1) };
#
#        my $selection = {
#                          includes => \@dirs,
#                         };
#        return $selection;
#    }
#
#    return {};
#}

# Overrides:
#   EBox::Report::DiskUsageProvider::_facilitiesForDiskUsage
#sub _facilitiesForDiskUsage
#{
#    my ($self) = @_;
#
#    my $usersPrintableName  = __(q{Users files});
#    my $usersPath           = EBox::SambaLdapUser::usersPath();
#    my $groupsPrintableName = __(q{Groups files});
#    my $groupsPath          = EBox::SambaLdapUser::groupsPath();
#
#    return {
#        $usersPrintableName   => [ $usersPath ],
#        $groupsPrintableName  => [ $groupsPath ],
#    };
#}

# Implement LogHelper interface
sub tableInfo
{
    my ($self) = @_;

    my $access_titles = {
        'timestamp' => __('Date'),
        'client' => __('Client address'),
        'username' => __('User'),
        'event' => __('Action'),
        'resource' => __('Resource'),
    };
    my @access_order = qw(timestamp client username event resource);
    my $access_events = {
        'connect' => __('Connect'),
        'opendir' => __('Access to directory'),
        'readfile' => __('Read file'),
        'writefile' => __('Write file'),
        'disconnect' => __('Disconnect'),
        'unlink' => __('Remove'),
        'mkdir' => __('Create directory'),
        'rmdir' => __('Remove directory'),
        'rename' => __('Rename'),
    };

    my $virus_titles = {
        'timestamp' => __('Date'),
        'client' => __('Client address'),
        'filename' => __('File name'),
        'virus' => __('Virus'),
        'event' => __('Type'),
    };
    my @virus_order = qw(timestamp client filename virus event);;
    my $virus_events = { 'virus' => __('Virus') };

    my $quarantine_titles = {
        'timestamp' => __('Date'),
        'filename' => __('File name'),
        'qfilename' => __('Quarantined file name'),
        'event' => __('Quarantine'),
    };
    my @quarantine_order = qw(timestamp filename qfilename event);
    my $quarantine_events = { 'quarantine' => __('Quarantine') };

    return [{
        'name' => __('Samba access'),
        'tablename' => 'samba_access',
        'titles' => $access_titles,
        'order' => \@access_order,
        'timecol' => 'timestamp',
        'filter' => ['client', 'username', 'resource'],
        'types' => { 'client' => 'IPAddr' },
        'events' => $access_events,
        'eventcol' => 'event'
    },
    {
        'name' => __('Samba virus'),
        'tablename' => 'samba_virus',
        'titles' => $virus_titles,
        'order' => \@virus_order,
        'timecol' => 'timestamp',
        'filter' => ['client', 'filename', 'virus'],
        'types' => { 'client' => 'IPAddr' },
        'events' => $virus_events,
        'eventcol' => 'event'
    },
    {
        'name' => __('Samba quarantine'),
        'tablename' => 'samba_quarantine',
        'titles' => $quarantine_titles,
        'order' => \@quarantine_order,
        'timecol' => 'timestamp',
        'filter' => ['filename'],
        'events' => $quarantine_events,
        'eventcol' => 'event'
    }];
}

sub logHelper
{
    my ($self) = @_;

    return (new EBox::SambaLogHelper);
}

#sub report
#{
#    my ($self, $beg, $end, $options) = @_;
#    my $maxTopActivityUsers = $options->{'max_top_activity_users'};
#    my $maxTopActivityGroups = $options->{'max_top_activity_groups'};
#    my $maxTopSizeShares = $options->{'max_top_size_shares'};
#    my $maxTopVirusShares = $options->{'max_top_virus_shares'};
#
#    my $report = {};
#
#    $report->{'activity'} = $self->runMonthlyQuery($beg, $end, {
#        'select' => 'COALESCE(SUM(operations), 0) AS OPERATIONS',
#        'from' => 'samba_access_report'
#    });
#
#    $report->{'top_activity_users'} = $self->runQuery($beg, $end, {
#        'select' => 'username, SUM(operations) AS operations',
#        'from' => 'samba_access_report',
#        'group' => 'username',
#        'limit' => $maxTopActivityUsers,
#        'order' => 'operations DESC'
#    });
#
#
#    $report->{top_activity_groups} = _topActivityGroups($self, $beg, $end, $maxTopActivityGroups);
#
#    $report->{'top_size_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, type, AVG(size) AS size',
#        'from' => 'samba_disk_usage_report',
#        'group' => 'share, type',
#        'limit' => $maxTopSizeShares,
#        'order' => 'size DESC',
#    });
#
#    $report->{'top_size_user_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, AVG(size) AS size',
#        'from' => 'samba_disk_usage_report',
#        'group' => 'share',
#        'limit' => $maxTopSizeShares,
#        'order' => 'size DESC',
#        'where' => q{type = 'user'}
#    });
#
#    $report->{'top_size_group_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, AVG(size) AS size',
#        'from' => 'samba_disk_usage_report',
#        'group' => 'share, type',
#        'limit' => $maxTopSizeShares,
#        'order' => 'size DESC',
#        'where' => q{type = 'group'}
#    });
#
#    $report->{'top_size_custom_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, AVG(size) AS size',
#        'from' => 'samba_disk_usage_report',
#        'group' => 'share, type',
#        'limit' => $maxTopSizeShares,
#        'order' => 'size DESC',
#        'where' => q{type = 'custom'}
#    });
#
#    $report->{'top_virus_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, SUM(virus) as virus',
#        'from' => 'samba_virus_share_report',
#        'group' => 'share',
#        'limit' => $maxTopVirusShares,
#        'order' => 'virus DESC',
#    });
#
#
#    return $report;
#}
#
#sub _topActivityGroups
#{
#    my ($self, $beg, $end, $maxTopActivityGroups) = @_;
#    my $usersMod = EBox::Global->modInstance('users');
#
#    my $sqlResult = $self->runQuery($beg, $end, {
#        'select' => 'username, SUM(operations) AS operations',
#        'from' => 'samba_access_report',
#        'group' => 'username',
#    });
#    my %operationsByUser;
#    foreach my $i (0 .. $#{ $sqlResult->{username} } ) {
#        $operationsByUser{ $sqlResult->{username}->[$i] } =  $sqlResult->{operations}->[$i];
#    }
#
#    delete $sqlResult->{username};
#    delete $sqlResult->{operations};
#
#
#    my $min = -1;
#    my @groupsAndOperations;
#    foreach my $group_r ($usersMod->groups()) {
#        my $groupname = $group_r->{account};
#        my $operations = 0;
#
#        my @users = @{ $usersMod->usersInGroup($groupname) };
#        foreach my $user (@users) {
#            $operations += $operationsByUser{$user};
#        }
#
#
#        if (@groupsAndOperations <   $maxTopActivityGroups ) {
#            push @groupsAndOperations, [$groupname => $operations];
#        } elsif ($operations > $min) {
#            pop @groupsAndOperations;
#            push @groupsAndOperations, [$groupname => $operations];
#        } else {
#            next;
#        }
#
#        @groupsAndOperations = sort { $b->[1] <=> $a->[1]  } @groupsAndOperations;
#        $min = $groupsAndOperations[-1]->[1];
#    }
#
#    my @topGroups     = map { $_->[0]  } @groupsAndOperations;
#    my @topOperations = map { $_->[1] } @groupsAndOperations;
#    return {
#            'groupname' => \@topGroups,
#            'operations' => \@topOperations,
#           };
#}
#
#sub consolidateReportQueries
#{
#    return [
#        {
#            'target_table' => 'samba_access_report',
#            'query' => {
#                'select' => 'username, COUNT(event) AS operations',
#                'from' => 'samba_access',
#                'group' => 'username'
#            },
#            quote => { username => 1 },
#        },
#        {
#            'target_table' => 'samba_virus_report',
#            'query' => {
#                'select' => 'client, COUNT(event) AS virus',
#                'from' => 'samba_virus',
#                'group' => 'client'
#            },
#            quote => { client => 1 },
#        },
#        {
#            'target_table' => 'samba_disk_usage_report',
#            'query' => {
#                'select' => 'share, type, CAST (AVG(size) AS int) AS size',
#                'from' => 'samba_disk_usage',
#                'group' => 'share, type'
#
#            },
#            quote => { share => 1 },
#        },
#        {
#            'target_table' => 'samba_virus_share_report',
#            'query' => {
#                'select' => 'share, count(*) as virus',
#                'from' => 'samba_quarantine',
#                'where' => q{event='quarantine'},
#                'group' => 'filename'
#            },
#            'rowConversor' => \&_virusShareReportRowConversor,
#            'targetGroupFields' => ['share'],
#            quote => { share => 1 },
#        },
#    ];
#}
#
#my @sharesSortedByPathLen;
#
#sub _updatePathsByLen
#{
#    my ($self) = @_;
#
#    my $ldapInfo = EBox::SambaLdapUser->new();
#    @sharesSortedByPathLen = map {
#         { path => $_->{path},
#           share => $_->{sharename} }
#    } ( @{ $ldapInfo->userShareDirectories },
#        @{ $ldapInfo->groupShareDirectories }
#      );
#
#    foreach my $sh_r (@{ $self->shares(1) }) {
#        push @sharesSortedByPathLen, {path => $sh_r->{path},
#                                      share =>  $sh_r->{share} };
#    }
#
#    # add regexes
#    foreach my $share (@sharesSortedByPathLen) {
#        my $path = $share->{path};
#        $share->{pathRegex} = qr{^$path/};
#    }
#
#    @sharesSortedByPathLen = sort {
#        length($b->{path}) <=>  length($a->{path})
#    } @sharesSortedByPathLen;
#}
#
#sub _shareByFilename
#{
#    my ($filename) = @_;
#
#    if (not @sharesSortedByPathLen) {
#        my $samba =EBox::Global->modInstance('samba');
#        $samba->_updatePathsByLen();
#    }
#
#
#    foreach my $shareAndPath (@sharesSortedByPathLen) {
#        if ($filename =~ m/$shareAndPath->{pathRegex}/) {
#            return $shareAndPath->{share};
#        }
#    }
#
#
#    return undef;
#}
#
#sub _virusShareReportRowConversor
#{
#    my ($row) = @_;
#    my $filename = delete $row->{filename};
#    my $share = _shareByFilename($filename);
#    EBox::debug("COBV $filename -> $share");
#    if ($share) {
#        $row->{share} = $share;
#    } else {
#        return undef;
#    }
#
#
#    return $row;
#}
#
#sub logReportInfo
#{
#    my ($self) = @_;
#
#    if ($self->_diskUsageAlreadyCheckedToday) {
#        return [];
#    }
#
#    my @reportData;
#
#    my %shareByPath;
#
#    my @shares = @{ $self->_sharesAndSizes() };
#
#
#    foreach my $share (@shares) {
#        # add info about disk usage by share
#        my $entry = {
#                     table => 'samba_disk_usage',
#                     values => {
#                                share => $share->{share},
#                                size  => $share->{size},
#                                type  => $share->{type},
#                               }
#                    };
#        push @reportData, $entry;
#    }
#
#    return \@reportData;
#}
#
#sub _diskUsageAlreadyCheckedToday
#{
#    my ($self) = @_;
#
#    my $db = EBox::DBEngineFactory::DBEngine();
#    my $query = q{SELECT share FROM samba_disk_usage WHERE (timestamp >= (current_date + interval '0 day')) AND (timestamp < (current_date + interval '1 day'))};
#    my $results = $db->query($query);
#    return @{ $results } > 0;
#}
#
#sub _sharesAndSizes
#{
#    my ($self) = @_;
#
#    my $ldapInfo = EBox::SambaLdapUser->new();
#    my @shares;
#
#    foreach my $sh_r ( @{ $ldapInfo->userShareDirectories }) {
#        my $share = {
#                     share => $sh_r->{sharename},
#                     path  => $sh_r->{path},
#                     type  => 'user',
#                    };
#        push @shares, $share;
#    }
#
#    foreach my $sh_r ( @{ $ldapInfo->groupShareDirectories }) {
#        my $share = {
#                     share => $sh_r->{sharename},
#                     path  => $sh_r->{path},
#                     type  => 'group',
#                    };
#        push @shares, $share;
#    }
#
#    # add no-account shares to share list
#    foreach my $sh_r (@{ $self->shares(1)  }) {
#        my $share = {
#                     share => $sh_r->{share},
#                     path  => $sh_r->{path},
#                     type  => 'custom',
#                    };
#        push @shares, $share;
#    }
#
#
#    foreach my $share (@shares) {
#        my $path = $share->{path};
#        if (EBox::Sudo::fileTest('-d', $path)) {
#            my $output = EBox::Sudo::rootWithoutException("du -ms '$path'");
#
#            my ($size) =  $output->[0] =~ m{^(\d+)};
#            if (not defined $size) {
#                EBox::error("Problem getting $path size: @{$output}");
#                $size = 0;
#            }
#
#            $share->{size} = $size;
#        }
#    }
#
#    return \@shares;
#}

# Generate, store in the given file and return a password
sub _savePassword
{
    my ($self, $pass, $file) = @_;

    my ($login, $password, $uid, $gid) = getpwnam('ebox');
    EBox::Module::Base::writeFile($file, $pass,
            { mode => '0600', uid => $uid, gid => $gid });

    return $pass;
}

# Method: ldb
#
#   Provides an EBox::LDB object with the proper settings
#
sub ldb
{
    my ($self) = @_;

    unless (defined ($self->{ldb})) {
        $self->{ldb} = EBox::LDB->instance();
    }
    return $self->{ldb};
}

# Method: sharesPaths
#
#   This function is used to generate disk usage reports. It
#   returns the shares paths, excluding the group shares.
#
sub sharesPaths
{
    my ($self) = @_;

    my $shares = $self->shares(1);
    my $paths = [];

    foreach my $share (@{$shares}) {
        push (@{$paths}, $share->{path}) unless defined $share->{groupShare};
    }

    return $paths;
}

# Method: userPaths
#
#   This function is used to generate disk usage reports. It
#   returns all the paths where a user store data
#
sub userPaths
{
    my ($self, $user) = @_;

    my $userProfilePath = EBox::SambaLdapUser::PROFILESPATH;
    $userProfilePath .= "/" . $user->get('uid');

    my $paths = [];
    push (@{$paths}, $user->get('homeDirectory'));
    push (@{$paths}, $userProfilePath);

    return $paths;
}

# Method: groupPaths
#
#   This function is used to generate disk usage reports. It
#   returns the group share path if it is configured.
#
sub groupPaths
{
    my ($self, $group) = @_;

    my $groupName = $group->get('cn');
    my $shares = $self->shares(1);
    my $paths = [];

    foreach my $share (@{$shares}) {
        if (defined $groupName and defined $share->{groupShare} and
            $groupName eq $share->{groupShare}) {
            push (@{$paths}, $share->{path});
            last;
        }
    }

    return $paths;
}

1;
