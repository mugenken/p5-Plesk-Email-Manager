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

sub BUILD {
    my ($self) = @_;

    $self->config(Config::Auto::parse($self->configfile));
    $self->_get_servers;

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

sub _fetch_all {
    my ($self) = @_;

    my $base_dsn = 'dbi:mysql';

    my $domains;
    my $domains_ips;
    my $domains_resolved;

    for my $hostname (keys %{$self->servers}){
        say "working on $hostname";
        my $database = $self->servers->{$hostname}->{Db};
        my $username = $self->servers->{$hostname}->{DbUser};
        my $password = $self->servers->{$hostname}->{DbPassword};
        my $port     = 3306;

        my $dsn = "$base_dsn:$database:$hostname:$port";
        my $dbh = DBI->connect($dsn, $username, $password) or die $!;

        $domains = $self->_query($dbh, $self->config->{Queries}->{domains});
        $domains_ips = $self->_query($dbh, $self->config->{Queries}->{domains_ips});

        $dbh->disconnect;

        $self->_map_relay_domains($domains, $domains_ips);
    }

    $self->_merge_smpt_overrides;

    use Data::Dumper;
    say Dumper $self->relay_domains;

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

sub _merge_smpt_overrides {
    my ($self) = @_;

    my $relay_domains = $self->relay_domains;
    my $smtp_overrides = $self->config->{'Postfix: Domain-Smtp-Overrides'};

    @{$relay_domains}{keys %{$smtp_overrides}} = values %{$smtp_overrides};

    $self->relay_domains($relay_domains);

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


