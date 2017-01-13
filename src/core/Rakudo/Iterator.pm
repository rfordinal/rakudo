# This class contains generally usable methods creating Iterators.
# There are two reasons for having this in a separate class:
#
# 1. Nice to have a separate file for similar stuff.  Rakudo::Internals
#    has become a hodgepodge of stuff of late.
# 2. Improve readability/searchability of code using these iterators, as
#    many already have a long name, and having them prefixed with the more
#    general Rakudo::Internals in the code, as opposed for the definite
#    Rakudo::Iterator, feels better.

class Rakudo::Iterator {

#-------------------------------------------------------------------------------
# Roles that are used by iterators in the rest of the core settings, in
# alphabetical order for easier perusal.

    # Generic role for iterating over a Blob / Buf.  You need to
    # supply at least a .pull-one.  Takes a Blob / Buf as the only
    # parameter to .new.
    our role Blobby does Iterator {
        has $!blob;
        has Int $!i;   # sadly, this can not be a native int yet  :-(

        method SET-SELF(\blob) {
            nqp::if(
              nqp::isgt_i(nqp::elems(blob),0),
              nqp::stmts(               # something to iterator over
                ($!blob := blob),
                ($!i     = -1),
                self
              ),
              Rakudo::Iterator.Empty    # nothing to iterate
            )
        }
        method new(\blob) { nqp::create(self).SET-SELF(blob) }

        # We can provide a generic push-all to the iterator as the
        # result of a push-all is always immutable, so we can use
        # the atpos_i here in both cases.
        method push-all($target --> IterationEnd) {
            nqp::stmts(
              (my $blob := $!blob),     # attribute access is slower
              (my int $elems = nqp::elems($blob)),
              (my int $i = $!i),
              nqp::while(
                nqp::islt_i(($i = nqp::add_i($i,1)),$elems),
                $target.push(nqp::atpos_i($blob,$i))
              )
            )
        }
        method count-only() { nqp::p6box_i(nqp::elems($!blob)) }
        method sink-all(--> IterationEnd) { $!i = nqp::elems($!blob) }
    }

    # Generic role for iterating over a Map / Hash.  You must
    # at least provide your own .pull-one.  Takes a Map / Hash
    # as the only parameter to .new.
    our role Mappy does Iterator {
        has $!storage;
        has $!iter;

        method SET-SELF(\hash) {
            $!storage := nqp::getattr(hash,Map,'$!storage');
            nqp::if(
              ($!storage.DEFINITE && nqp::elems($!storage)),
              nqp::stmts(              # we have something to iterate over
                ($!iter := nqp::iterator($!storage)),
                self
              ),
              Rakudo::Iterator.Empty   # nothing to iterate
            )
        }
        method new(\hash) { nqp::create(self).SET-SELF(hash) }
        method count-only() { nqp::p6box_i(nqp::elems($!storage)) }
        method bool-only(--> True) { }
        method sink-all(--> IterationEnd) { $!iter := nqp::null }
    }

    # Generic role for iterating over a >1 dimensional shaped list
    # for its lowest branches.  The default .new method takes a List
    # to iterate over.  A consuming class needs to provide a .process
    # method, which will be called with each iteration with the
    # $!indices attribute set to the coordinates of the branch being
    # iterated for this time (with the highest element index set to 0).
    # Consuming class can optionally provide a .done method that will
    # be called just before the iterator returns IterationEnd.
    our role ShapeBranch does Iterator {
        has $!dims;
        has $!indices;
        has Mu $!list;
        has int $!maxdim;
        has int $!maxind;
        has int $!level;

        # Every time process() gets called, the following attributes are set:
        # $!indices  a list_i with current position, with the highest elem 0
        # $!level    level at which exhaustion happened
        # $!dims     a list_i with dimensions
        # $!maxdim   maximum element number in $!dims
        # $!maxind   maximum element number in lowest level list
        method process { ... }           # consumer needs to supply a .process
        method done(--> Nil) { }         # by default no action at end

        method dims() {                  # HLL version of $!dims
            nqp::stmts(
              (my $result := nqp::setelems(nqp::list,nqp::elems($!dims))),
              (my int $i = -1),
              nqp::while(                # convert list_i to list
                nqp::isle_i(($i = nqp::add_i($i,1)),$!maxdim),
                nqp::bindpos($result,$i,nqp::atpos_i($!dims,$i))
              ),
              $result
            )
        }

        method SET-SELF(Mu \list) {
            nqp::stmts(
              nqp::if(
                nqp::istype(list,List),
                nqp::stmts(                                 # List like
                  ($!list := nqp::getattr(list,List,'$!reified')),
                  (my $shape := list.shape),
                  (my int $dims = $shape.elems),     # reifies
                  ($!dims := nqp::setelems(nqp::list_i,$dims)),
                  (my int $i = -1),
                  nqp::while(
                    nqp::islt_i(($i = nqp::add_i($i,1)),$dims),
                    nqp::bindpos_i($!dims,$i,
                      nqp::atpos(nqp::getattr($shape,List,'$!reified'),$i))
                  )
                ),
                ($dims = nqp::elems($!dims := nqp::dimensions($!list := list)))
              ),
              ($!indices := nqp::setelems(nqp::list_i,$dims)),
              ($!maxdim = nqp::sub_i($dims,1)),
              ($!maxind = nqp::sub_i(nqp::atpos_i($!dims,$!maxdim),1)),
              self
            )
        }
        method new(Mu \list) { nqp::create(self).SET-SELF(list) }

        method pull-one() is raw {
            nqp::if(
              nqp::isge_i($!level,0),
              nqp::stmts(                      # still iterating
                (my $result := self.process),  # do the processing
                (my int $level = $!maxdim),
                nqp::until(                    # update indices
                  nqp::islt_i(                 # exhausted ??
                    ($level = nqp::sub_i($level,1)),0) # next level
                    || nqp::stmts(
                    nqp::bindpos_i($!indices,nqp::add_i($level,1),0),  # reset
                    nqp::islt_i(
                      nqp::bindpos_i($!indices,$level, # increment this level
                        nqp::add_i(nqp::atpos_i($!indices,$level),1)),
                      nqp::atpos_i($!dims,$level)      # out of range?
                    ),
                  ),
                  nqp::null
                ),
                ($!level = $level),            # set level for next call
                $result                        # what we found
              ),
              nqp::stmts(
                nqp::if(
                  nqp::iseq_i($!level,-1),
                  nqp::stmts(                  # first time telling we're done
                    self.done,                 # notify we're done
                    ($!level = -2)             # do this only once
                  )
                ),
                IterationEnd                   # done iterating
              )
            )
        }
    }

    # Generic role for iterating over a >1 dimensional shaped list
    # for its values (leaves).  The default .new method takes a List
    # to iterate over.  A consuming class needs to provide a .result
    # method, which will be called with each iteration with the
    # $!indices attribute set to the coordinates of the element being
    # iterated for this time.  In some cases, the iterator is iterated
    # over for the side-effects in .result only.  Which is why this
    # role supplies an optimized .sink-all.
    our role ShapeLeaf does Iterator {
        has $!dims;
        has $!indices;
        has Mu $!list;
        has int $!maxdim;
        has int $!max;

        # Every time .result gets called, the following attributes are set:
        # $!indices  a list_i with current coordinate
        # $!dims     a list_i with dimensions
        # $!maxdim   maximum element number in $!dims
        method result { ... }            # consumer needs to supply a .result

        method indices() {               # HLL version of $!indices
            nqp::stmts(
              (my $result := nqp::setelems(nqp::list,nqp::elems($!indices))),
              (my int $i = -1),
              nqp::while(                # convert list_i to list
                nqp::isle_i(($i = nqp::add_i($i,1)),$!maxdim),
                nqp::bindpos($result,$i,nqp::atpos_i($!indices,$i))
              ),
              $result
            )
        }
        method SET-SELF(Mu \list) {
            nqp::stmts(
              nqp::if(
                nqp::istype(list,List),
                nqp::stmts(                                 # List like
                  ($!list := nqp::getattr(list,List,'$!reified')),
                  (my $shape := list.shape),
                  (my int $dims = $shape.elems),            # reifies
                  ($!dims := nqp::setelems(nqp::list_i,$dims)),
                  (my int $i = -1),
                  nqp::while(
                    nqp::islt_i(($i = nqp::add_i($i,1)),$dims),
                    nqp::bindpos_i($!dims,$i,
                      nqp::atpos(nqp::getattr($shape,List,'$!reified'),$i))
                  )
                ),
                ($dims = nqp::elems($!dims := nqp::dimensions($!list := list)))
              ),
              ($!indices := nqp::setelems(nqp::list_i,$dims)),
              ($!maxdim = nqp::sub_i($dims,1)),
              ($!max    = nqp::atpos_i($!dims,$!maxdim)),
              self
            )
        }
        method new(Mu \list) { nqp::create(self).SET-SELF(list) }

        method pull-one() is raw {
            nqp::if(
              $!indices,
              nqp::stmts(                                 # still iterating
                (my $result := self.result),              # process
                nqp::if(
                  nqp::islt_i(
                    (my int $i =
                      nqp::add_i(nqp::atpos_i($!indices,$!maxdim),1)),
                    $!max
                  ),
                  nqp::bindpos_i($!indices,$!maxdim,$i),  # ready for next
                  nqp::stmts(                             # done for now
                    (my int $level = $!maxdim),
                    nqp::until(                           # update indices
                      nqp::islt_i(                        # exhausted ??
                        ($level = nqp::sub_i($level,1)),0)
                        || nqp::stmts(
                        nqp::bindpos_i($!indices,nqp::add_i($level,1),0),
                        nqp::islt_i(
                          nqp::bindpos_i($!indices,$level,
                            nqp::add_i(nqp::atpos_i($!indices,$level),1)),
                          nqp::atpos_i($!dims,$level)
                        ),
                      ),
                      nqp::null
                    ),
                    nqp::if(
                      nqp::islt_i($level,0),
                      $!indices := nqp::null              # done next time
                    )
                  )
                ),
                $result                                   # what we found
              ),
              IterationEnd                                # done now
            )
        }

        method push-all($target --> IterationEnd) {
            nqp::while(
              $!indices,
              nqp::stmts(                                   # still iterating
                (my int $i = nqp::atpos_i($!indices,$!maxdim)),
                nqp::while(
                  nqp::isle_i(($i = nqp::add_i($i,1)),$!max),
                  nqp::stmts(
                    $target.push(self.result),              # process
                    nqp::bindpos_i($!indices,$!maxdim,$i),  # ready for next
                  )
                ),
                (my int $level = $!maxdim),                 # done for now
                nqp::until(                                 # update indices
                  nqp::islt_i(                              # exhausted ??
                    ($level = nqp::sub_i($level,1)),0)
                    || nqp::stmts(
                    nqp::bindpos_i($!indices,nqp::add_i($level,1),0),
                    nqp::islt_i(
                      nqp::bindpos_i($!indices,$level,
                        nqp::add_i(nqp::atpos_i($!indices,$level),1)),
                      nqp::atpos_i($!dims,$level)
                    ),
                  ),
                  nqp::null
                ),
                nqp::if(
                  nqp::islt_i($level,0),
                  $!indices := nqp::null                    # done
                )
              )
            )
        }

        method sink-all(--> IterationEnd) {
            nqp::while(
              $!indices,
              nqp::stmts(                                   # still iterating
                (my int $i = nqp::atpos_i($!indices,$!maxdim)),
                nqp::while(
                  nqp::isle_i(($i = nqp::add_i($i,1)),$!max),
                  nqp::stmts(
                    self.result,                            # process
                    nqp::bindpos_i($!indices,$!maxdim,$i),  # ready for next
                  )
                ),
                (my int $level = $!maxdim),                 # done for now
                nqp::until(                                 # update indices
                  nqp::islt_i(                              # exhausted ??
                    ($level = nqp::sub_i($level,1)),0)
                    || nqp::stmts(
                    nqp::bindpos_i($!indices,nqp::add_i($level,1),0),
                    nqp::islt_i(
                      nqp::bindpos_i($!indices,$level,
                        nqp::add_i(nqp::atpos_i($!indices,$level),1)),
                      nqp::atpos_i($!dims,$level)
                    ),
                  ),
                  nqp::null
                ),
                nqp::if(
                  nqp::islt_i($level,0),
                  $!indices := nqp::null                    # done
                )
              )
            )
        }
    }

#-------------------------------------------------------------------------------
# Methods that generate an Iterator (in alphabetical order)

    # Create an iterator from a source iterator that will repeat the
    # values of the source iterator indefinitely *unless* a Whatever
    # was encountered, in which case it will repeat the last seen value
    # indefinitely (even if the source iterator wasn't actually exhausted).
    # Only if the source iterator did not produce any values at all, then
    # the resulting iterator will not produce any either.
    method DWIM(\source) {
        class :: does Iterator {
            has $!source;
            has $!buffer;
            has int $!ended;
            has int $!whatever;
            has int $!i;
            method !SET-SELF(\source) {
                $!source := source;
                $!buffer := IterationBuffer.new;
                self
            }
            method new(\source) { nqp::create(self)!SET-SELF(source) }

            method pull-one() is raw {
                nqp::if(
                  $!ended,
                  nqp::if(                          # source exhausted
                    $!whatever,
                    nqp::if(                        # seen a Whatever
                      nqp::elems($!buffer),
                      nqp::atpos($!buffer,          # last value seen
                        nqp::sub_i(nqp::elems($!buffer),1)),
                      Nil                           # no last value seen
                    ),
                    nqp::atpos($!buffer,            # not seen, so modulo repeat
                      nqp::mod_i(
                        nqp::sub_i(($!i = nqp::add_i($!i,1)),1),
                        nqp::elems($!buffer)
                      )
                    )
                  ),
                  nqp::if(                          # source not exhausted
                    nqp::eqaddr((my $value := $!source.pull-one),IterationEnd),
                    nqp::stmts(                     # exhausted now
                      ($!ended = 1),
                      nqp::if(
                        nqp::iseq_i(nqp::elems($!buffer),0),
                        IterationEnd,               # nothing to repeat, done
                        self.pull-one               # last or repeat
                      )
                    ),
                    nqp::if(                        # got a value
                      nqp::istype($value,Whatever),
                      nqp::stmts(                   # done, repeat last value
                        ($!whatever = $!ended = 1),
                        self.pull-one,
                      ),
                      nqp::stmts(                   # save / return value
                        $!buffer.push($value),
                        $value
                      )
                    )
                  )
                )
            }

            # Is the source iterator considered exhausted?
            method ended() { nqp::p6bool($!ended) }

            # Eat the iterator trying to find out the number of elements
            # produced by the iterator.  Intended to provide information
            # for error messages.
            method count-elems() {                  
                nqp::if(
                  $!ended,
                  nqp::elems($!buffer),
                  nqp::stmts(
                    (my int $elems = nqp::elems($!buffer)),
                    nqp::until(
                      nqp::eqaddr($!source.pull-one,IterationEnd),
                      $elems = nqp::add_i($elems,1)
                    ),
                    $elems
                  )
                )
            }
        }.new(source)
    }

    # Returns a sentinel Iterator object that will never generate any value.
    # Does not take a parameter.
    method Empty() {
        BEGIN class :: does Iterator {
            method new() { nqp::create(self) }
            method pull-one(--> IterationEnd)  { }
            method push-all($ --> IterationEnd) { }
            method sink-all(--> IterationEnd)  { }
            method count-only(--> 0) { }
            method bool-only(--> False) { }
        }.new
    }

    # Return an iterator that will cache a source iterator for the index
    # values that the index iterator provides, from a given offest in the
    # cached source iterator.  Values from the index iterator below the
    # offset, are considered to be illegal and will throw.  Also takes an
    # optional block to be called when an otherwise out-of-bounds index
    # value is given by the index iterator: if not given, Nil will be
    # returned for such index values.
    method FromIndexes(\source,\indexes,\offset,&out?) {
        class :: does Iterator {
            has $!source;
            has $!indexes;
            has int $!offset;
            has &!out;
            has $!cache;
            method !SET-SELF($!source,$!indexes,\offset,&!out) {
                $!cache := nqp::setelems(nqp::list,$!offset = offset);
                self
            }
            method new(\s,\i,\o,\out) { nqp::create(self)!SET-SELF(s,i,o,out) }
            method pull-one() is raw {
                nqp::if(
                  nqp::eqaddr((my $got := $!indexes.pull-one),IterationEnd),
                  IterationEnd,
                  nqp::if(
                    nqp::istype(                      # doesn't look like int
                      (my $number = +$got),Failure),
                    $number.throw,
                    nqp::if(                          # out of range
                      nqp::islt_i((my int $index = $number.Int),$!offset),
                      X::OutOfRange.new(:$got,:range("$!offset..^Inf")).throw,
                      nqp::if(
                        nqp::existspos($!cache,$index),
                        nqp::atpos($!cache,$index),   # it's in the cache
                        nqp::if(
                          nqp::defined($!source),
                          nqp::stmts(                 # can still search it
                            nqp::until(
                              nqp::existspos($!cache,$index)
                                || nqp::eqaddr(
                                     (my $pulled := $!source.pull-one),
                                     IterationEnd
                                   ),
                              nqp::push($!cache,$pulled)
                            ),
                            nqp::if(
                              nqp::eqaddr($pulled,IterationEnd),
                              nqp::stmts(
                                ($!source := Mu),
                                nqp::if(
                                  $!indexes.is-lazy,
                                  IterationEnd,       # not going to be any more
                                  nqp::stmts(         # didn't find it
                                    nqp::if(&out,out($index)),
                                    Nil
                                  )
                                )
                              ),
                              $pulled                 # found it
                            )
                          ),
                          nqp::stmts(                 # cannot be found
                            nqp::if(&out,out($index)),
                            Nil
                          )
                        )
                      )
                    )
                  )
                )
            }
            method is-lazy() { $!source.is-lazy }
        }.new(source,indexes,offset,&out)
    }

    # Create iterator for the last N values of a given iterator.  Needs
    # to specify the :action part of X::Cannot::Lazy in case the given
    # iterator is lazy.  Optionally returns an empty iterator if the
    # given iterator produced fewer than N values.
    method LastNValues(\iterator, \n, \action, $full = 0) {
        class :: does Iterator {
            has $!iterator;
            has int $!size;
            has int $!full;
            has $!lastn;
            has int $!todo;
            has int $!index;
            method !SET-SELF(\iterator, \size, $action, \full) {
                nqp::if(
                  ($!iterator := iterator).is-lazy,
                  X::Cannot::Lazy.new(:$action).throw,
                  nqp::if(
                    nqp::isle_i(size, 0),
                    Rakudo::Iterator.Empty,
                    nqp::stmts(
                      ($!full = full),
                      ($!lastn := nqp::setelems(nqp::list, $!size = size)),
                      nqp::setelems($!lastn, 0),
                      self
                    )
                  )
                )
            }
            method new(\i,\n,\a,\f) { nqp::create(self)!SET-SELF(i,n,a,f) }
            method !next() is raw {
                nqp::stmts(
                  (my int $index = $!index),
                  ($!index = nqp::mod_i(nqp::add_i($!index,1),$!size)),
                  ($!todo  = nqp::sub_i($!todo,1)),
                  nqp::atpos($!lastn,$index)
                )
            }
            method pull-one() is raw {
                nqp::if(
                  $!todo,
                  self!next,
                  nqp::if(
                    nqp::defined($!iterator),
                    nqp::stmts(
                      (my int $index),
                      (my int $size = $!size),
                      nqp::until(
                        nqp::eqaddr(
                          (my $pulled := $!iterator.pull-one),IterationEnd),
                        nqp::stmts(
                          nqp::bindpos($!lastn, $index, $pulled),
                          ($index = nqp::mod_i(nqp::add_i($index,1),$size))
                        )
                      ),
                      nqp::if(
                        nqp::iseq_i(nqp::elems($!lastn),$size),   # full set
                        nqp::stmts(
                          ($!index = $index),
                          ($!todo  = $!size)
                        ),
                        ($!todo =       # not a full set, $!index still at 0
                          nqp::if($!full,0,nqp::elems($!lastn))),
                      ),
                      ($!iterator := Mu),                   # done iterating
                      nqp::if($!todo, self!next, IterationEnd)
                    ),
                    IterationEnd
                  )
                )
            }
        }.new(iterator, n, action, $full)
    }

    # Return the last value of the given source iterator (if any).
    # Also needs the action string to be used in X::Cannot::Lazy if
    # the source iterator turns out to be lazy.
    method LastValue(\iterator, $action) is raw {
        nqp::if(
          iterator.is-lazy,
          X::Cannot::Lazy.new(:$action).throw,
          nqp::stmts(
            (my $result := IterationEnd),
            nqp::until(
              nqp::eqaddr((my $pulled := iterator.pull-one),IterationEnd),
              ($result := $pulled)
            ),
            $result
          )
        )
    }

    # An often occurring use of the Mappy role to generate all of the
    # values of a Map / Hash.  Takes a Map / Hash as the only parameter.
    method Mappy-values(\map) {
        class :: does Mappy {
            method pull-one() is raw {
                nqp::if(
                  $!iter,
                  nqp::iterval(nqp::shift($!iter)),
                  IterationEnd
                )
            }
            method push-all($target --> IterationEnd) {
                nqp::while(  # doesn't sink
                  $!iter,
                  $target.push(nqp::iterval(nqp::shift($!iter)))
                )
            }
        }.new(map)
    }

    # Return an iterator that will iterate over a source iterator and an
    # iterator generating monotonically increasing index values from a
    # given offset.  Optionally, call block if an out-of-sequence index
    # value is obtained, or simply ignore out of sequence index values.
    method MonotonicIndexes(\source,\indexes,\offset,&out?) {
        class :: does Iterator {
            has $!source;     # source iterator
            has $!indexes;    # iterator providing index values
            has int $!next;   # virtual index of next source value
            has &!out;        # callable for out of sequence values
            method !SET-SELF($!source,$!indexes,\offset,&!out) {
                $!next = offset;
                self
            }
            method new(\s,\i,\o,\out) { nqp::create(self)!SET-SELF(s,i,o,out) }
            method pull-one() is raw {
                nqp::stmts(
                  nqp::until(
                    nqp::eqaddr(
                      (my $got := $!indexes.pull-one),
                      IterationEnd
                    ),
                    nqp::if(
                      nqp::istype((my $number = +$got),Failure),
                      $number.throw,
                      nqp::if(
                        nqp::isle_i($!next,(my int $index = $number.Int)),
                        nqp::stmts(                      # possibly valid index
                          nqp::while(
                            nqp::islt_i($!next,$index) && $!source.skip-one,
                            ($!next = nqp::add_i($!next,1))
                          ),
                          (return nqp::if(
                            nqp::iseq_i($!next,$index),
                            nqp::stmts(
                              ($!next = nqp::add_i($!next,1)),
                              $!source.pull-one
                            ),
                            IterationEnd
                          ))
                        ),
                        nqp::if(&out,out($index,$!next)) # out of sequence
                      )
                    )
                  ),
                  IterationEnd
                )
            }
        }.new(source,indexes,offset,&out)
    }

    # Returns an iterator for the next N values of given iterator.
    method NextNValues(\iterator,\times) {
        class :: does Iterator {
            has $!iterator;
            has int $!times;
            method !SET-SELF($!iterator,$!times) { self }
            method new(\i,\t) { nqp::create(self)!SET-SELF(i,t) }
            method pull-one() is raw {
                nqp::if(
                  nqp::isgt_i($!times,0),
                  nqp::if(
                    nqp::eqaddr(
                      (my $pulled := $!iterator.pull-one),
                      IterationEnd
                    ),
                    nqp::stmts(
                      ($!times = 0),
                      IterationEnd
                    ),
                    nqp::stmts(
                      ($!times = nqp::sub_i($!times,1)),
                      $pulled
                    )
                  ),
                  IterationEnd
                )
            }
        }.new(iterator,times)
    }

    # Return an iterator for a List that has been completely reified
    # already.  Returns an nqp::null for elements don't exist before
    # the end of the reified list.
    method ReifiedList(\list) {
        class :: does Iterator {
            has $!reified;
            has int $!i;

            method !SET-SELF(\list) {
                nqp::stmts(
                  ($!reified := nqp::getattr(list,List,'$!reified')),
                  ($!i = -1),
                  self
                )
            }
            method new(\list) { nqp::create(self)!SET-SELF(list) }

            method pull-one() is raw {
                nqp::ifnull(
                  nqp::atpos($!reified,$!i = nqp::add_i($!i,1)),
                  nqp::if(
                    nqp::islt_i($!i,nqp::elems($!reified)), # found a hole
                    nqp::null,                              # it's a hole
                    IterationEnd                            # it's the end
                  )
                )
            }
            method push-all($target --> IterationEnd) {
                nqp::stmts(
                  (my int $elems = nqp::elems($!reified)),
                  (my int $i = $!i), # lexicals are faster than attributes
                  nqp::while(  # doesn't sink
                    nqp::islt_i(($i = nqp::add_i($i,1)),$elems),
                    $target.push(nqp::atpos($!reified,$i))
                  ),
                  ($!i = $i)
                )
            }
            method skip-one(--> 1) { $!i = nqp::add_i($!i,1) }
            method count-only() { nqp::p6box_i(nqp::elems($!reified)) }
            method bool-only()  { nqp::p6bool(nqp::elems($!reified)) }
            method sink-all(--> IterationEnd) { }
        }.new(list)
    }

    # Returns an iterator from a given iterator where the occurrence of
    # a Whatever value indicates that last value seen from the source
    # iterator should be repeated indefinitely until either another
    # non-Whatever value is seen from the source iterator, or the source
    # iterator is exhausted.
    method Whatever(\source) {
        class :: does Iterator {
            has $!source;
            has $!last;
            has int $!whatever;
            method new(\source) {
                nqp::p6bindattrinvres(nqp::create(self),self,'$!source',source)
            }
            method pull-one() is raw {
                nqp::if(
                  $!whatever,
                  nqp::if(                          # we're repeating
                    nqp::iseq_i($!whatever,2),      # source exhausted, repeat
                    $!last,
                    nqp::if(
                      nqp::eqaddr(
                        (my $value := $!source.pull-one),
                        IterationEnd
                      ),
                      nqp::stmts(                   # exhausted now, repeat
                        ($!whatever = 2),
                        $!last
                      ),
                      nqp::if(
                        nqp::istype($value,Whatever),
                        $!last,                     # another Whatever, repeat
                        nqp::stmts(                 # something else, no repeat
                          ($!whatever = 0),
                          ($!last := $value)
                        )
                      )
                    )
                  ),
                  nqp::if(                          # not repeating
                    nqp::eqaddr(
                      ($value := $!source.pull-one),
                      IterationEnd
                    ),
                    IterationEnd,                   # exhausted, stop
                    nqp::if(
                      nqp::istype($value,Whatever), # start repeating
                      nqp::stmts(
                        ($!whatever = 1),
                        $!last
                      ),
                      ($!last := $value)            # keep value for repeat
                    )
                  )
                )
            }
        }.new(source)
    }
}

# vim: ft=perl6 expandtab sw=4
