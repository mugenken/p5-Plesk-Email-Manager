package Plesk::Email::Manager::MakeConfig;

use Moo;
use 5.010;
use warnings;
use autodie;
use Try::Tiny;
use Config::Auto;
use Socket;
use File::Copy;
use DBI;
use Python::Serialise::Pickle;
use Email::Sender::Simple 'sendmail';
use Email::Simple;
use Email::Simple::Creator;

has configfile => ( is => 'rw' );
has config => ( is => 'rw' );
has servers => ( is => 'rw' );
has domain_structure => ( is => 'rw' );

has alias_map => ( is => 'rw' );
has relay_domains => ( is => 'rw' );
has relay_recipients => ( is => 'rw' );

sub BUILD {
    my ($self) = @_;

    $self->config(Config::Auto::parse($self->configfile));
    die "No Servers." unless $self->config->{Servers};
    $self->_get_servers;

    return 1;
}

sub run {
    my ($self) = @_;

    $self->_fetch_domains;
    $self->_process_relay_domains;
    $self->_fetch_mailboxes;

    $self->_generate_postfix_config;
    $self->_postmap_and_reload;
    $self->_generate_pickle_file if $self->config->{ConfigFiles}->{pickle_file};

    return 1;
}

sub _get_servers {
    my ($self) = @_;

    my %servers;

    for my $server (keys %{$self->config->{Servers}}){
        $servers{$self->config->{Servers}->{$server}} = $self->config->{$server};
    }

    $self->servers({%servers});

    return 1;
}

sub _fetch_mailboxes {
    my ($self) = @_;

    my $base_dsn = 'dbi:mysql';

    for my $hostname (keys %{$self->servers}){
        my $database = $self->servers->{$hostname}->{Db};
        my $username = $self->servers->{$hostname}->{DbUser};
        my $password = $self->servers->{$hostname}->{DbPassword};
        my $port     = 3306;

        my $dsn = "$base_dsn:$database:$hostname:$port";
        my $dbh;
        try {
            $dbh = DBI->connect($dsn, $username, $password, {RaiseError => 1});
        }
        catch {
            $self->_notify($_, 'deadly');
        };

        my $mailboxes = $self->_query($dbh, $self->config->{Queries}->{mailboxes});
        my $aliases   = $self->_query($dbh, $self->config->{Queries}->{mail_aliases});
        my $catch_alls = $self->_query($dbh, $self->config->{Queries}->{catch_alls});

        $dbh->disconnect;

        # merge aliases with mailboxes
        push @$mailboxes, $_ for @$aliases;

        $self->_map_relay_recipients($catch_alls, $mailboxes);
        $self->_merge_alias_map;
    }

    return 1;
}

sub _map_relay_recipients {
    my ($self, $catch_alls, $mailboxes) = @_;

    my $addresses = $self->relay_recipients // {};
    my @catch_alls = _flatten(@$catch_alls);
    my @smtp_overrides = keys %{ $self->config->{'Postfix: Domain-Smtp-Overrides'} };
    my @mailbox_exceptions = keys %{ $self->config->{'Postfix: Mailbox-Exceptions'} };
    my $domain_structure = $self->domain_structure;

    for (@{$mailboxes}){
        my ($user, $domain) = @$_;
        if ($self->_in_domain_list($domain)){
            for (@catch_alls){
                $user = '' if $domain eq $_;
                $domain_structure->{$domain}->{CatchAll} = 1;
            }
            my $address = $user . '@' . $domain;
            $addresses->{$address} = 'OK';
            push @{$domain_structure->{$domain}->{MailBoxes}}, $user if $user;
        }
    }

    $self->domain_structure($domain_structure);

    for (@smtp_overrides){
        my $domain = '@' . $_;
        $addresses->{$domain} = 'OK';
    }

    for (@mailbox_exceptions){
        $addresses->{$_} = 'OK';
    }

    $self->relay_recipients($addresses);

    return 1;
}

sub _merge_alias_map {
    my ($self) = @_;

    my $alias_map = $self->alias_map;
    my $domain_structure = $self->domain_structure;
    my $relay_recipients = $self->relay_recipients;

    for my $domain (keys %$alias_map){
        for my $alias (@{$alias_map->{$domain}}){
            if ($domain_structure->{$domain}->{CatchAll}){
                my $address = '@' . $alias;
                $relay_recipients->{$address} = 'OK';
            }
            else {
                for my $mailbox (@{$domain_structure->{$domain}->{MailBoxes}}){
                    my $address = $mailbox . '@' . $alias;
                    $relay_recipients->{$address} = 'OK';
                }
            }
        }
    }

    $self->relay_recipients($relay_recipients);

    return 1;
}

sub _fetch_domains {
    my ($self) = @_;

    my $base_dsn = 'dbi:mysql';

    for my $hostname (keys %{$self->servers}){
        my $database = $self->servers->{$hostname}->{Db};
        my $username = $self->servers->{$hostname}->{DbUser};
        my $password = $self->servers->{$hostname}->{DbPassword};
        my $port     = 3306;

        my $dsn = "$base_dsn:$database:$hostname:$port";
        my $dbh;
        try {
            $dbh = DBI->connect($dsn, $username, $password, {RaiseError => 1});
        }
        catch {
            $self->_notify($_, 'deadly');
        };

        my $domains = $self->_query($dbh, $self->config->{Queries}->{domains});
        my $domain_aliases = $self->_query($dbh, $self->config->{Queries}->{domain_aliases});
        my $domains_ips = $self->_query($dbh, $self->config->{Queries}->{domains_ips});
        my $server_ip_addresses = $self->_query($dbh, $self->config->{Queries}->{server_ip_addresses});

        $dbh->disconnect;

        $self->_map_relay_domains($domains, $domains_ips, $server_ip_addresses);
        $self->_map_aliases_to_domains($domain_aliases);
    }

    return 1;
}

sub _process_relay_domains {
    my ($self) = @_;

    $self->_merge_smpt_overrides;
    $self->_add_trandport_to_relay_domains;
    $self->_merge_transport_exceptions;

    return 1;
}

sub _query {
    my ($self, $dbh, $query) = @_;

    my $sth = $dbh->prepare($query);
    $sth->execute;

    return $sth->fetchall_arrayref;
}

sub _map_relay_domains {
    my ($self, $domains, $domains_ips, $server_ip_addresses) = @_;

    my @server_ip_addresses = _flatten(@$server_ip_addresses);
    my $domains_resolved = $self->relay_domains // {};

    $domains_ips = _aref_to_href($domains_ips);

    for (_flatten(@$domains)){
        my $packed_ip = gethostbyname($_);
        if (defined $packed_ip){
            my $ip_addr = inet_ntoa($packed_ip);

            # check if resolved address is in servers ip addresses and matches
            # domains ip address configured in Plesk
            if ($domains_ips->{$_} ~~ $ip_addr && grep { $_ ~~ $ip_addr } @server_ip_addresses){
                $domains_resolved->{$_} = $ip_addr;
            }
        }
    }

    $self->relay_domains($domains_resolved);

    return 1;
}

sub _map_aliases_to_domains {
    my ($self, $domain_aliases) = @_;

    my $alias_map = $self->alias_map // {};
    my $relay_domains = $self->relay_domains;

    for (@$domain_aliases){
        my ($alias, $domain) = @$_;
        next unless $self->_in_domain_list($domain);

        # only aliases that resolv correctly
        my $packed_ip = gethostbyname($alias);
        if (defined $packed_ip){
            $alias_map->{$domain} = [] unless defined $alias_map->{$domain};
            my $ip_addr = inet_ntoa($packed_ip);

            if ($relay_domains->{$domain} ~~ $ip_addr){
                push @{$alias_map->{$domain}}, $alias;
                $relay_domains->{$alias} = $ip_addr;
            }
        }

        $self->relay_domains($relay_domains);
    }

    $self->alias_map($alias_map);

    return 1;
}

sub _merge_smpt_overrides {
    my ($self) = @_;

    my $relay_domains = $self->relay_domains;
    my $smtp_overrides = $self->config->{'Postfix: Domain-Smtp-Overrides'};

    # merge with slice of hashrefs
    @{$relay_domains}{keys %{$smtp_overrides}} = values %{$smtp_overrides};

    $self->relay_domains($relay_domains);

    return 1;
}

sub _add_trandport_to_relay_domains {
    my ($self) = @_;

    my $relay_domains = $self->relay_domains;
    my %domain_structure;

    for (keys %{$relay_domains}){
        # should be all smtp here. exceptions will be merged later
        $relay_domains->{$_} = 'smtp:' . $relay_domains->{$_};
        $domain_structure{$_} = {
            CatchAll => 0,
            MailBoxes => [],
        };
    }

    $self->relay_domains($relay_domains);
    $self->domain_structure({%domain_structure});

    return 1;
}

sub _merge_transport_exceptions {
    my ($self) = @_;

    my $relay_domains = $self->relay_domains;
    my $transport_exceptions = $self->config->{'Postfix: Domain-Exceptions'};

    # add dummy values
    for (keys %{$transport_exceptions}){
        my ($transport, $value) = split ':', $transport_exceptions->{$_};
        $value = 'dummy' unless defined $value;
        $transport_exceptions->{$_} = $transport . ':' . $value;
    }

    @{$relay_domains}{keys %{$transport_exceptions}} = values %{$transport_exceptions};

    return 1;
}

sub _generate_postfix_config {
    my ($self) = @_;

    my $relay_domains = $self->config->{ConfigFiles}->{relay_domains};
    my $relay_recipient_maps = $self->config->{ConfigFiles}->{relay_recipient_maps};

    open my $rd_fh, '>', $relay_domains . '.tmp';
    for (keys %{ $self->relay_domains }){
        print $rd_fh $_ . "\t" . $self->relay_domains->{$_} . "\n";
    }
    close $rd_fh;

    open my $rrm_fh, '>', $relay_recipient_maps . '.tmp';
    for (keys %{ $self->relay_recipients }){
        print $rrm_fh $_ . "\t" . $self->relay_recipients->{$_} . "\n";
    }
    close $rrm_fh;

    move($relay_recipient_maps . '.tmp', $relay_recipient_maps);
    move($relay_domains . '.tmp', $relay_domains);

    return 1;

}

sub _postmap_and_reload {
    my ($self) = @_;

    my $relay_domains = $self->config->{ConfigFiles}->{relay_domains};
    my $relay_recipient_maps = $self->config->{ConfigFiles}->{relay_recipient_maps};

    my $postmap = '/usr/sbin/postmap';
    my $postfix_init = '/etc/init.d/postfix';
    if ($self->config->{Executables}->{postmap}){
        $postmap = $self->config->{Executables}->{postmap}
    }
    if ($self->config->{Executables}->{postfix_init}){
        $postfix_init = $self->config->{Executables}->{postfix_init}
    }

    system $postmap, $relay_domains;
    system $postmap, $relay_recipient_maps;
    system $postfix_init, 'reload';

    return 1;
}

sub _generate_pickle_file {
    my ($self) = @_;

    my $file = $self->config->{ConfigFiles}->{pickle_file};
    my $pkl = Python::Serialise::Pickle->new('>' . $file);
    $pkl->dump($self->domain_structure);

    return 1;
}

sub _in_domain_list {
    my ($self, $domain) = @_;

    for (keys %{ $self->relay_domains }){
        return 1 if $domain eq $_;
    }

    return 0;
}

sub _flatten {
    map @$_, @_;
}

sub _aref_to_href {
    my ($aref) = @_;
    die unless ref $aref eq 'ARRAY';

    my $href = {};

    for (@$aref){
        my ($key, $value) = @$_;
        $href->{$key} = $value;
    }

    return $href;
}

sub _notify {
    my ($self, $message, $deadly) = @_;

    my $email = Email::Simple->create(
        header => [
            To      => $self->config->{Notify}->{notify_address},
            From    => $self->config->{Notify}->{from_address},
            Subject => $self->config->{Notify}->{subject},
        ],
        body => $message,
    );

    sendmail($email);

    exit 1 if $deadly;

    return 1;
}

