package Plesk::Email::Manager::MakeConfig;

use Moo;
use 5.010;
use feature 'say';
use warnings;
use Config::Auto;
use Socket;
use DBI;
use DBD::mysql;

has configfile => ( is => 'rw' );
has config => ( is => 'rw' );
has servers => ( is => 'rw' );
has domain_aliases => ( is => 'rw' );
has mailboxes => ( is => 'rw' );
has mail_aliases => ( is => 'rw' );
has catch_alls => ( is => 'rw' );

has relay_domains => ( is => 'rw' );
has relay_recipients => ( is => 'rw' );

sub BUILD {
    my ($self) = @_;

    $self->config(Config::Auto::parse($self->configfile));
    $self->_get_servers;

    return 1;
}

sub run {
    my ($self) = @_;

    #$self->_fetch_domains;
    #$self->_process_relay_domains;

    $self->_fetch_mailboxes;

    use Data::Dumper;
    say Dumper $self->relay_recipients;

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

sub _fetch_domains {
    my ($self) = @_;

    my $base_dsn = 'dbi:mysql';

    for my $hostname (keys %{$self->servers}){
        say "working on $hostname";
        my $database = $self->servers->{$hostname}->{Db};
        my $username = $self->servers->{$hostname}->{DbUser};
        my $password = $self->servers->{$hostname}->{DbPassword};
        my $port     = 3306;

        my $dsn = "$base_dsn:$database:$hostname:$port";
        my $dbh = DBI->connect($dsn, $username, $password) or die $!;

        my $domains = $self->_query($dbh, $self->config->{Queries}->{domains});
        my $domains_ips = $self->_query($dbh, $self->config->{Queries}->{domains_ips});

        $dbh->disconnect;

        $self->_map_relay_domains($domains, $domains_ips);
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

sub _fetch_mailboxes {
    my ($self) = @_;

    my $base_dsn = 'dbi:mysql';

    for my $hostname (keys %{$self->servers}){
        say "working on $hostname";
        my $database = $self->servers->{$hostname}->{Db};
        my $username = $self->servers->{$hostname}->{DbUser};
        my $password = $self->servers->{$hostname}->{DbPassword};
        my $port     = 3306;

        my $dsn = "$base_dsn:$database:$hostname:$port";
        my $dbh = DBI->connect($dsn, $username, $password) or die $!;

        my $mailboxes = $self->_query($dbh, $self->config->{Queries}->{mailboxes});
        my $aliases   = $self->_query($dbh, $self->config->{Queries}->{mail_aliases});
        my $catch_alls = $self->_query($dbh, $self->config->{Queries}->{catch_alls});

        $dbh->disconnect;

        # merge aliases with mailboxes
        push @$mailboxes, $_ for @$aliases;

        $self->_map_relay_recipients($catch_alls, $mailboxes);
    }

    return 1;
}

sub _query {
    my ($self, $dbh, $query) = @_;

    my $sth = $dbh->prepare($query);
    $sth->execute;

    return $sth->fetchall_arrayref;
}

sub _map_relay_domains {
    my ($self, $domains, $domains_ips) = @_;

    my $domains_resolved = $self->relay_domains // {};
    $domains_ips = _aref_to_href($domains_ips);

    for (_flatten(@$domains)){
        my $packed_ip = gethostbyname($_);
        if (defined $packed_ip){
            my $ip_addr = inet_ntoa($packed_ip);
            $domains_resolved->{$_} = $ip_addr if $domains_ips->{$_} ~~ $ip_addr;
        }
    }

    $self->relay_domains($domains_resolved);

    return 1;
}

sub _map_relay_recipients {
    my ($self, $catch_alls, $mailboxes) = @_;

    my $addresses = $self->relay_recipients // {};
    my @catch_alls = _flatten(@$catch_alls);
    my @smtp_overrides = keys %{ $self->config->{'Postfix: Domain-Smtp-Overrides'} };
    my @mailbox_exceptions = keys %{ $self->config->{'Postfix: Mailbox-Exceptions'} };

    for (@{$mailboxes}){
        my ($user, $domain) = @$_;
        for (@catch_alls){
            $user = '' if $domain eq $_;
        }
        my $address = $user . '@' . $domain;
        $addresses->{$address} = 'OK';
    }

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

    for (keys %{$relay_domains}){
        # should be all smtp here. exceptions will be merged later
        $relay_domains->{$_} = 'smtp:' . $relay_domains->{$_};
    }

    $self->relay_domains($relay_domains);

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


