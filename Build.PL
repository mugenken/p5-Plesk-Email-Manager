use 5.006;
use strict;
use warnings;
use lib 'lib';
use Module::Build;
use Getopt::Long;
use Plesk::Email::Manager::Version;

my @script_files = grep { -f and ! -d } glob 'script/*';
my $v = Plesk::Email::Manager::Version->new;
my $install = 0;
my $dist    = 0;

GetOptions(
    'install' => \$install,
    'dist'    => \$dist,
);


my $build = Module::Build->new(
    module_name         => 'Plesk::Email::Manager',
    license             => 'perl',
    dist_author         => 'Mugen Kenichi <mugen.kenichi@uninets.eu>',
    dist_abstract       => 'Some code to handle multiple plesk servers with a single mail gateway.',
    dist_version_from   => 'lib/Plesk/Email/Manager/Version.pm',

    build_requires => {
        'Test::More' => 0,
        'Module::Build' => 0,
    },

    requires => {
        'perl' => 5.010,
        'Config::Auto' => 0,
        'Moo'  => 0,
        'DBI' => 0,
        'DBD::mysql' => 0,
        'indirect' => 0,
        'multidimensional' => 0,
        'bareword::filehandles' => 0,
        'Python::Serialise::Pickle' => 0,
        'Email::Simple' => 0,
        'Email::Sender::Simple' => 0,
    },

    script_files => [@script_files],

    add_to_cleanup      => [ 'Plesk-Email-Manager-* Build _build MYMETA.* Makefile.PL' ],
    create_makefile_pl  => 'traditional',

    meta_add            => {
        no_index => {
            directory => ['t'],
        },
        version => $v->get,
        release_status => 'unstable',
    },

    meta_merge => {
        provides => {
            'Plesk::Email::Manager' => {
                file => 'Plesk/Email/Manager.pm',
                version => $v->get,
            },
            'Plesk::Email::Manager::MakeConfig' => {
                file => 'Plesk/Email/Manager/MakeConfig.pm',
                version => $v->get,
            },
            'Plesk::Email::Manager::Version' => {
                file => 'Plesk/Email/Manager/Version.pm',
                version => $v->get,
            },
        },
    },
);

$build->dispatch('build');
#$build->dispatch('test');

if ($dist) {
    $build->dispatch('distmeta');
    $build->dispatch('dist');
}

if ($install) {
    $build->dispatch('install');
}
else {
    print "Execute ./Build install to install Projected\n";
}

$build->create_build_script();
