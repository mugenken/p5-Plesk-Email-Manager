package Plesk::Email::Manager::MakeConfig;

use Moo;
use 5.010;
use warnings;
use Config::Auto;
use DBI;
use DBD::mysql;

has configfile => ( is => 'rw' );
has config => ( is => 'rw' );
has servers => ( is => 'rw' );
has responses => ( is => 'rw' );

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
        $self->_query_domains($dbh);

    }
}

sub _query_domains {
    my ($self, $dbh) = @_;
    my $query = 'SELECT name FROM domains';
    my $query_handle = $dbh->prepare($query);

    my $domain_name;

    $query_handle->execute;
    $query_handle->bind_columns(\$domain_name);
    while ($query_handle->fetch){
        say $domain_name;
    }

    return 1;
}

sub _query_domain_aliases {
    my ($self, $dbh) = @_;
    my $query = 'SELECT da.name, d.name
                    FROM domainaliases
                    AS da
                        INNER JOIN domains
                            AS d
                    ON da.dom_id = d.id
                    WHERE da.mail = "true"';

    return 1;
}

sub _query_mailboxes {
    my ($self, $dbh) = @_;
    my $query = 'SELECT m.mail_name, d.name
                     FROM mail
                        AS m
                            INNER JOIN domains
                                AS d
                     ON m.dom_id = d.id';

    return 1;
}

sub _query_mail_aliases {
    my ($self, $dbh) = @_;
    my $query = 'SELECT ma.alias, d.name
                    FROM (
                        mail_aliases
                        AS ma
                            INNER JOIN mail
                                AS m
                        ON ma.mn_id = m.id
                    )
                    INNER JOIN domains
                        AS d
                    ON m.dom_id = d.id';

    return 1;
}

sub _query_catch_alls {
    my ($self, $dbh) = @_;
    my $query = 'SELECT d.name
                    FROM (
                        domains
                        AS d
                            INNER JOIN Parameters
                                AS p1
                        ON d.id = p1.id
                    )
                    INNER JOIN Parameters
                        AS p2
                    ON d.id = p2.id
                    WHERE p1.parameter = "catch_addr"
                    AND p2.parameter = "nonexist_mail"
                    AND p2.value = "catch"';

    return 1;
}



