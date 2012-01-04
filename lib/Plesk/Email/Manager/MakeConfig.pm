package Plesk::Email::Manager::MakeConfig;

use Moo;
use 5.010;
use feature 'say';
use warnings;
use Config::Auto;
use DBI;
use DBD::mysql;

has configfile => ( is => 'rw' );
has config => ( is => 'rw' );
has servers => ( is => 'rw' );
has domains => ( is => 'rw' );
has domain_aliases => ( is => 'rw' );
has domains_ips => ( is => 'rw' );
has mailboxes => ( is => 'rw' );
has mail_aliases => ( is => 'rw' );
has catch_alls => ( is => 'rw' );

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

    for my $hostname (keys %{$self->servers}){
        say "working on $hostname";
        my $database = $self->servers->{$hostname}->{Db};
        my $username = $self->servers->{$hostname}->{DbUser};
        my $password = $self->servers->{$hostname}->{DbPassword};
        my $port     = 3306;

        my $dsn = "$base_dsn:$database:$hostname:$port";
        my $dbh = DBI->connect($dsn, $username, $password) or die $!;
        $self->domains($self->_query($dbh, $self->config->{Queries}->{domains}));
        $self->domains_ips($self->_query($dbh, $self->config->{Queries}->{domains_ips}));
        $dbh->disconnect;
        use Data::Dumper;
        say Dumper $self->domains;
        say Dumper $self->domains_ips;
    }
}

sub _query {
    my ($self, $dbh, $query) = @_;

    my $sth = $dbh->prepare($query);
    $sth->execute;

    return $sth->fetchall_arrayref;
}

