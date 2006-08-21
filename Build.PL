use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name       => 'HTTP::Async',
    license           => 'perl',
    dist_author       => 'Edmund von der Burg <evdb@ecclestoad.co.uk>',
    dist_version_from => 'lib/HTTP/Async.pm',

    requires => {
        'Carp'           => 0,
        'Data::Dumper'   => 0,
        'HTTP::Request'  => 0,
        'HTTP::Response' => 0,
        'HTTP::Status'   => 0,
        'IO::Select'     => 0,
        'Net::HTTP'      => 0,
        'Net::HTTP::NB'  => 0,
        'Time::HiRes'    => 0,
        'URI'            => 0,
    },

    build_requires => {
        'HTTP::Server::Simple::CGI'  => 0,
        'Module::Build'              => 0,
        'Test::HTTP::Server::Simple' => 0,
        'Test::More'                 => 0,
    },
);

$builder->create_build_script();
