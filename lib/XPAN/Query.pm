package XPAN::Query;

use 5.010001;
use strict;
use warnings;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       list_xpan_packages
                       list_xpan_modules
                       list_xpan_dists
                       list_xpan_authors
               );

our %SPEC;

# VERSION
# DATE

1;
# ABSTRACT: Query a {CPAN,MiniCPAN,DarkPAN} mirror

=head1 SYNOPSIS

 use XPAN::Query qw(
     list_xpan_packages
     list_xpan_modules
     list_xpan_dists
     list_xpan_authors
 );
 my $res = list_ubuntu_releases(detail=>1);
 # raw data is in $Ubuntu::Releases::data;


=head1 DESCRIPTION

B<INITIAL RELEASE: no implementations yet>.

XPAN is a term I coined for any repository (directory tree, be it on a local
filesystem or a remote network) that has structure like a CPAN mirror,
specifically having a C<modules/02packages.details.txt.gz> file. This includes a
normal CPAN mirror, a MiniCPAN, or a DarkPAN. Currently it I<excludes> BackPAN,
because it does not have C<02packages.details.txt.gz>, only
C<authors/id/C/CP/CPANID> directories.

With this module, you can query various things about the repository. This module
fetches C<02packages.details.txt.gz> and parses it (caching it locally for a
period of time).


=head1 SEE ALSO

L<Parse::CPAN::Packages>

L<Parse::CPAN::Packages::Fast>

L<PAUSE::Packages>, L<PAUSE::Users>

Tangentially related: L<BackPAN::Index>

=cut
