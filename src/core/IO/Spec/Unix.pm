my class IO::Spec::Unix is IO::Spec {

    method canonpath( $patharg, :$parent --> Str:D) {
        nqp::if(
          (my str $path = $patharg.Str),
          nqp::stmts(
            nqp::while(                # // -> /
              nqp::isne_i(nqp::index($path,'//'),-1),
              $path = nqp::join('/',nqp::split('//',$path))
            ),
            nqp::while(                # /./ -> /
              nqp::isne_i(nqp::index($path,'/./'),-1),
              $path = nqp::join('/',nqp::split('/./',$path))
            ),
            nqp::if(                   # /. $ -> /
              nqp::eqat($path,'/.',nqp::sub_i(nqp::chars($path),2)),
              $path = nqp::substr($path,0,nqp::sub_i(nqp::chars($path),1))
            ),
            nqp::if(                   # ^ ./ ->
              nqp::eqat($path,'./',0) && nqp::isgt_i(nqp::chars($path),2),
              $path = nqp::substr($path,2)
            ),
            nqp::if(
              $parent,
              nqp::stmts(
                nqp::while(          # ^ /.. -> /
                  ($path ~~ s:g {  [^ | <?after '/'>] <!before '../'> <-[/]>+ '/..' ['/' | $ ] } = ''),
                  nqp::null
                ),
                nqp::unless(
                  $path,
                  $path = '.'
                )
              )
            ),
            nqp::if(                       # ^ /
              nqp::eqat($path,'/',0),
              nqp::stmts(
                nqp::while(                # ^ /../ -> /
                  nqp::eqat($path,'/../',0),
                  $path = nqp::substr($path,3)
                ),
                nqp::if(                   # ^ /.. $ -> /
                  nqp::iseq_s($path,'/..'),
                  $path = '/'
                )
              )
            ),
            nqp::if(                       # .+/ -> .+
              nqp::isgt_i(nqp::chars($path),1)
                && nqp::eqat($path,'/',nqp::sub_i(nqp::chars($path),1)),
              nqp::substr($path,0,nqp::sub_i(nqp::chars($path),1)),
              $path
            )
          ),
          ''
        )
    }

    method dir-sep  {  '/' }
    method curdir   {  '.' }
    method updir    { '..' }
    method curupdir { none('.','..') }
    method rootdir  { '/' }
    method devnull  { '/dev/null' }

    method basename(\path) {
        my str $str = nqp::unbox_s(path);
        my int $index = nqp::rindex($str,'/');
        nqp::p6bool($index == -1)
          ?? path
          !! substr(path,nqp::box_i($index + 1,Int) );
    }

    method extension(\path) {
        my str $str = nqp::unbox_s(path);
        my int $index = nqp::rindex($str,'.');
        nqp::p6bool($index == -1)
          ?? ''
          !! substr(path,nqp::box_i($index + 1,Int) );
    }

    method tmpdir {
        my $io;
        first( {
            if .defined {
                $io = .IO;
                $io.d && $io.r && $io.w && $io.x;
            }
          },
          %*ENV<TMPDIR>,
          '/tmp',
        ) ?? $io !! IO::Path.new(".");
    }

    method is-absolute( $file ) {
        substr( $file, 0, 1 ) eq '/';
    }

    method path {
        if %*ENV<PATH> -> $PATH {
            $PATH.split( ':' ).map: { $_ || '.' };
        }
        else {
            ();
        }
    }

    method splitpath( $path, :$nofile = False ) {
        if $nofile {
            ( '', $path, '' );
        }
        else {
            $path ~~ m/^ ( [ .* \/ [ '.'**1..2 $ ]? ]? ) (<-[\/]>*) /;
            ( '', ~$0, ~$1 );
        }
    }

    multi method split(IO::Spec::Unix: Cool:D $path is copy ) {
        $path  ~~ s/<?after .> '/'+ $ //;

        $path  ~~ m/^ ( [ .* \/ ]? ) (<-[\/]>*) /;
        my ($dirname, $basename) = ~$0, ~$1;

        $dirname ~~ s/<?after .> '/'+ $ //; #/

        if $basename eq '' {
            $basename = '/'  if $dirname eq '/';
        }
        else {
            $dirname = '.'  if $dirname eq '';
        }
        # shell dirname '' produces '.', but we don't because it's probably user error

        # temporary, for the transition period
        (:volume(''), :$dirname, :$basename, :directory($dirname));
#        (:volume(''), :$dirname, :$basename);
    }


    method join ($, \dir, \file) {
        self.catpath(
            '',
            nqp::if(
                nqp::unless(
                    nqp::if( nqp::iseq_s(dir, '/'), nqp::iseq_s(file, '/'), ),
                    nqp::if( nqp::iseq_s(dir, '.'), file ),
                ),
                '',
                dir,
            ),
            file,
        );
    }

    method catpath( $, \dirname, \file ) {
        nqp::if(
            nqp::if(
                nqp::isne_s(dirname, ''),
                nqp::if(
                    nqp::isne_s(file, ''),
                    nqp::if(
                        nqp::isfalse(nqp::eqat(
                            dirname, '/', nqp::sub_i(nqp::chars(dirname), 1)
                        )),
                        nqp::isfalse(nqp::eqat(file, '/', 0)),
                    ),
                ),
            ),
            nqp::concat(dirname, nqp::concat('/', file)),
            nqp::concat(dirname, file),
        )
    }

    method catdir( *@parts ) { self.canonpath( (flat @parts, '').join('/') ) }
    method splitdir( $path ) { $path.split( '/' )  }
    method catfile( |c )     { self.catdir(|c) }

    method abs2rel( $path is copy, $base is copy = Str ) {
        $base = $*CWD unless $base;

        if self.is-absolute($path) || self.is-absolute($base) {
            $path = self.rel2abs( $path );
            $base = self.rel2abs( $base );
        }
        else {
            # save a couple of cwd()s if both paths are relative
            $path = self.catdir( self.rootdir, $path );
            $base = self.catdir( self.rootdir, $base );
        }

        my ($path_volume, $path_directories) = self.splitpath( $path, :nofile );
        my ($base_volume, $base_directories) = self.splitpath( $base, :nofile );

        # Can't relativize across volumes
        return $path unless $path_volume eq $base_volume;

        # For UNC paths, the user might give a volume like //foo/bar that
        # strictly speaking has no directory portion.  Treat it as if it
        # had the root directory for that volume.
        if !$base_directories && self.is-absolute( $base ) {
            $base_directories = self.rootdir;
        }

        # Now, remove all leading components that are the same
        my @pathchunks = self.splitdir( $path_directories );
        my @basechunks = self.splitdir( $base_directories );

        if $base_directories eq self.rootdir {
            @pathchunks.shift;
            return self.canonpath( self.catpath('', self.catdir( @pathchunks ), '') );
        }

        while @pathchunks && @basechunks && @pathchunks[0] eq @basechunks[0] {
            @pathchunks.shift;
            @basechunks.shift;
        }
        return self.curdir unless @pathchunks || @basechunks;

        # $base now contains the directories the resulting relative path
        # must ascend out of before it can descend to $path_directory.
        my $result_dirs = self.catdir( self.updir() xx @basechunks.elems, @pathchunks );
        return self.canonpath( self.catpath('', $result_dirs, '') );
    }

    method rel2abs( $path, $base? is copy) {
        return self.canonpath($path) if self.is-absolute($path);

        my $cwd := $*CWD;
        if !self.is-absolute( $base //= $cwd ) {
            $base = self.rel2abs( $base, $cwd ) unless $base eq $cwd;
        }
        self.catdir( self.canonpath($base), $path );
    }
}

# vim: ft=perl6 expandtab sw=4
