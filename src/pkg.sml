
structure Pkg = struct

(* Some utilities *)
fun println s = print (s ^ "\n")

fun isPrefixList (nil,_) = true
  | isPrefixList (x::xs,y::ys) = x = y andalso isPrefixList (xs,ys)
  | isPrefixList _ = false

fun isInPkgDir (from_dir:string) (f:string) : bool =
    isPrefixList(System.splitPath from_dir, System.splitPath f)

fun is_in e l = List.exists (fn x => x = e) l

type filepath = string
type pkgpath = Manifest.pkgpath
type buildlist = Solve.buildlist

infix </>
val op </> = System.</>

val smlpkg_filename = Manifest.smlpkg_filename

(* Installing packages *)

fun installInDir (bl:buildlist) (dir:filepath) : unit =
  let fun putEntry from_dir pdir (entry:Zip.entry) =
          (* The archive may contain all kinds of other stuff that we don't want. *)
          if not (isInPkgDir from_dir (Zip.eRelativePath entry))
             orelse System.hasTrailingPathSeparator (Zip.eRelativePath entry) then ()
          else
            (* Since we are writing to paths indicated in a zipfile we
               downloaded from the wild Internet, we are going to be a
               little bit paranoid.  Specifically, we want to avoid
               writing outside of the 'lib/' directory.  We do this by
               bailing out if the path contains any '..' components.
               We have to use System.FilePath.Posix, because the zip
               library claims to encode filepaths with '/' directory
               seperators no matter the host OS. *)
            if is_in ".." (System.splitPath (Zip.eRelativePath entry)) then
              raise Fail ("Zip archive for " ^ pdir ^ " contains suspicious path: " ^
                          Zip.eRelativePath entry)
            else
              let val f = pdir </> System.makeRelative from_dir (Zip.eRelativePath entry)
              in System.createDirectoryIfMissing true (OS.Path.dir f)
               ; System.writeFileBin f (Zip.fromEntry entry)
              end

  in List.app (fn (p,v) =>
                  let val info = PkgInfo.lookupPackageRev p v
                      val a = Zip.download (PkgInfo.pkgRevZipballUrl info)
                      val m = PkgInfo.pkgRevGetManifest info
                      (* Compute the directory in the zipball that should contain the
                         package files. *)
                      val from_dir =
                          case Manifest.pkg_dir m of
                              SOME d => PkgInfo.pkgRevZipballDir info d
                            | NONE => raise Fail (smlpkg_filename() ^ " for " ^
                                                  ^ Manifest.pkgpathToString p ^ "-"
                                                  ^ SemVer.toString v
                                                  ^ " does not define a package path.")
                      (* The directory in the local file system that will contain the
                         package files. *)
                      val pdir = dir </> Manifest.pkgpathToString p
                      (* Remove any existing directory for this package.  This is a bit
                         inefficient, as the likelihood that the old ``lib`` directory
                         already contains the correct version is rather high.  We should
                         have a way to recognise this situation, and not download the
                         zipball in that case. *)
                  in System.removePathForcibly pdir
                   ; System.createDirectoryIfMissing true pdir
                   ; List.app (putEntry from_dir pdir) (Zip.zEntries a)
                  end
              ) (M.toList bl)
  end

val (libDir:filepath, libNewDir:filepath, libOldDir:filepath) =
    ("lib", "lib~new", "lib~old")

(*
 Install the packages listed in the build list in the 'lib'
 directory of the current working directory.  Since we are touching
 the file system, we are going to be very paranoid.  In particular,
 we want to avoid corrupting the 'lib' directory if something fails
 along the way.

 The procedure is as follows:

 1) Create a directory 'lib~new'.  Delete an existing 'lib~new' if
 necessary.

 2) Populate 'lib~new' based on the build list.

 3) Rename 'lib' to 'lib~old'.  Delete an existing 'lib~old' if
 necessary.

 4) Rename 'lib~new' to 'lib'

 5) If the current package has package path 'p', move 'lib~old/p' to
 'lib~new/p'.

 6) Delete 'lib~old'.

 Since POSIX at least guarantees atomic renames, the only place this
 can fail is between steps 3, 4, and 5.  In that case, at least the
 'lib~old' will still exist and can be put back by the user.
*)

fun installBuildList (p:pkgpath option) (bl:buildlist) : unit =
    let val libdir_exists = System.doesDirExist libDir

        val () = System.removePathForcibly libNewDir                (* 1 *)
        val () = System.createDirectoryIfMissing false libNewDir

        val () = installInDir bl libNewDir                          (* 2 *)

        val () = if libdir_exists then                              (* 3 *)
                   ( System.removePathForcibly libOldDir
                   ; System.renameDirectory libDir libOldDir)
                 else ()

        val () = System.renameDirectory libNewDir libDir            (* 4 *)

        val () = case Option.map Manifest.pkgpathToString p of      (* 5 *)
                     SOME pfp =>
                     if libdir_exists then
                       let val pkgdir_exists = System.doesDirExist (libOldDir </> pfp)
                       in if pkgdir_exists then
                            (* Ensure the parent directories exist so that we can move the
                               package directory directly. *)
                            ( System.createDirectoryIfMissing true (takeDirectory (libDir </> pfp))
                            ; System.renameDirectory (libOldDir </> pfp) (libDir </> pfp))
                          else ()
                       end
                     else ()

        val () = if libdir_exists then                    (* 6 *)
                 then System.removePathForcibly libOldDir
                 else ()
    in ()
    end

fun getPkgManifest () : Manifest.t =
    let val smlpkg = smlpkg_filename ()
        val () = if System.doesDirExist smlpkg then
                   raise Fail (smlpkg ^
                               " exists, but it is a directory!  What in Odin's beard...")
    in if System.doesFileExist smlpkg then
         Manifest.fromFile smlpkg
       else ( log (smlpkg ^ " not found - pretending it's empty.")
            ; Manifest.empty NONE)
    end

fun putPkgManifest (m:Manifest.t) : unit =
    System.writeFile (smlpkg_filename()) (Manifest.toString m)

(* The Command-line interface *)

fun usageMsg s =
    let val prog = CommandLine.name()
    in print ("Usage: " ^ prog ^ " [--version] [--help] " ^ s ^ "\n")
     ; OS.Process.exit(OS.Process.failure)
    end

fun simpleUsage () =
    usageMsg ("options... <" ^
              String.concatWith "|" (map #1 commands)
              ^ ">")

fun doFmt args =
    case args of
        [] => let val smlpkg = smlpkg_filename()
                  val m = Manifest.fromFile smlpkg
              in System.writeFile smlpkg (Manifest.toString m)
              end
      | _ => simpleUsage()

fun doCheck args =
    case args of
        [] => let val m = getPkgManifest()
                  val bl = Solve.solveDeps (Manifest.pkgRevDeps m)
                  val () = print "Dependencies chosen:\n"
                  val () = print (prettyBuildList bl)
              in case Manifest.package m of
                     NONE => ()
                   | SOME pkgpath =>
                     let val pdir = "lib" </> Manifest.pkgpathToString pkgpath
                         val pdir_exists = OS.FileSys.isDir pdir
                     in if pdir_exists then ()
                        else raise Fail ("Problem: the directory " ^ pdir ^ " does not exist.")
                     end
              end
      | _ => simpleUsage()

fun doSync args =
    case args of
        [] => let val m = getPkgManifest()
                  val bl = Solve.solveDeps (Manifest.pkgRevDeps m)
              in installBuildList (Manifest.package m) bl
              end
      | _ => simpleUsage()

fun pkgpathParse (s:string) : pkgpath =
    case Manifest.pkgpathFromString s of
        SOME p => p
      | NONE => raise Fail ("expecting package path - got '" ^ s ^ "'.")

fun semverParse (s:string) : semver =
    case SemVer.fromString s of
        SOME v => v
      | NONE => raise Fail ("expecting semantic version - got '" ^ s ^ "'.")

fun doAdd' (p:pkgpath) (v:semver) : unit =
    let val m = getPkgManifest()

        (* See if this package (and its dependencies) even exists.  We
           do this by running the solver with the dependencies already
           in the manifest, plus this new one.  The Monoid instance
           for PkgRevDeps is left-biased, so we are careful to use the
           new version for this package. *)

        val () = Solve.solveDeps (M.add (p,(v,NONE)) (Manifest.pkgRevDeps m))

        (* We either replace any existing occurence of package 'p', or
           we add a new one. *)
        val p_info = PkgInfo.lookupPackageRev p v
        val hash_opt = case (SemVer.major v, SemVer.minor v, SemVer.patch v) of
                           (* We do not perform hash-pinning for
                              (0,0,0)-versions, because these already embed a
                              specific revision ID into their version number. *)
                           (0,0,0) => NONE
                         | _ => SOME (PkgInfo.pkgRevCommit p_info)
        val req = (p, v, hash_opt)
        val prev_r = Manifest.get_required m p
        val m = case prev_r of
                    SOME _ => let val m = Manifest.del_required p m
                              in Manifest.add_required req m
                              end
                  | NONE => Manifest.add_required req m
        val () =
            case prev_r of
                SOME prev_r' =>
                if #2 prev_r' = v
                then println ("Package already at version " ^ SemVer.toString v ^
                              "; nothing to do.")
                else println ("Replaced " ^ Manifest.pkgpathToString p ^ " " ^
                              SemVer.toString (#2 prev_r') ^ " => " ^
                              SemVer.toString v ^ ".")
              | NONE => println ("Added new required package " ^ Manifest.pkgpathToString p ^
                                 " " ^ SemVer.toString v ^ ".")
    in putPkgManifest m
     ; println ("Remember to run '" ^ CommandLine.name() ^ " sync'.")
    end

fun doAdd args : unit =
    case args of
        [p, v] => doAdd' (pkgpathParse p) (semverParse v)
      | [p] => doAdd' (pkgpathParse p) (PkgInfo.lookupNewestRev (pkgpathParse p))
      | _ => simpleUsage()

fun doRemove args : unit =
    case args of
        [p as ps] =>
        let val m = getPkgManifest()
            val p = pkgpathParse p
        in case Manifest.get_required m p of
               SOME r =>
               let val m = Manifest.del_required p m
               in putPkgManifest m
                ; println ("Removed " ^ ps ^ " " ^ SemVer.toString (#2 r) ^ ".")
               end
             | NONE =>
               raise Fail ("No package " ^ ps ^ " found in " ^ smlpkg_filename() ^ ".")
        end
      | _ => simpleUsage()

fun doInit args =
    case args of
        [p as ps] =>
        let val smlpkg = smlpkg_filename()
            val () = if System.doesFileExist smlpkg orelse System.doesDirExist smlpkg
                     then raise Fail (smlpkg ^ " already exists.")
                     else ()
            val p = pkgpathParse p
            val () = System.createDirectoryIfMissing true ("lib" </> ps)
            val () = println("Created directory 'lib/" ^ ps ^ "'.")
            val m = Manifest.empty (SOME p)
        in putPkgManifest m
         ; println ("Wrote " ^ smlpkg_filename() ^ ".")
        end
      | _ => simpleUsage()

fun doUpgrade args : unit =
    case args of
        [] =>
        let fun upgrade (req:required) : required =
                let val v = PkgInfo.lookupNewestRev (requiredPkg req)
                    val h = PkgInfo.pkgRevCommit (PkgInfo.lookupPackageRev (requiredPkg req) v)
                in if v <> (#2 req) then
                     ( println ("Upgraded " ^ Manifest.pkgpathToString (#1 req) ^ " " ^
                                SemVer.toString (#2 req) ^ " => " ^
                                SemVer.toString v ^ ".")
                     ; (#1 req, v, SOME h)
                     )
                   else req
                end
            val m = getPkgManifest()
            val rs0 = Manifest.requires m
            val rs = List.map upgrade rs0
            val m = Manifest.replace_requires m rs
        in putPkgManifest m
         ; (if rs = rs0 then println ("Nothing to upgrade.")
            else println ("Remember to run '" ^ CommandLine.name() ^ " sync'."))
        end
      | _ => simpleUsage()


fun doVersions args : unit =
    case args of
        [p] =>
        let val p = Manifest.pkgpathParse p
            val pinfo = PkgInfo.lookupPackage p
            val versions = PkgInfo.pkgVersions pinfo
        in List.app (println o SemVer.toString) (M.keys versions)
        end
      | _ => simpleUsage()

fun eatFlags args =
    case args of
        arg :: args => if arg = "-v" orelse arg = "--verbose"
                       then (verboseFlag := true; eatFlags args)
                       else args
      | nil => args

fun main () =
    let val smlpkg = smlpkg_filename ()
        val commands = [ ("add",
                          (doAdd, "Add another required package to " ^ smlpkg ^ "."))
                       , ("check",
                          (doCheck, "Check that " ^ smlpkg ^ " is satisfiable."))
                       , ("init",
                          (doInit, "Create a new " ^ smlpkg ^ " and a lib/ skeleton."))
                       , ("fmt",
                          (doFmt, "Reformat " ^ smlpkg ^ "."))
                       , ("sync",
                          (doSync, "Populate lib/ as specified by " ^ smlpkg ^ "."))
                       , ("remove",
                          (doRemove, "Remove a required package from " ^ smlpkg ^ "."))
                       , ("upgrade",
                          (doUpgrade, "Upgrade all packages to newest versions."))
                       , ("versions",
                          (doVersions, "List available versions for a package."))
                       ]

        fun look s l =
            Option.map #2 (List.find (fn (k,v) => s=k) l)

        fun doUsage () =
            let val k = List.foldl Int.max 0 (map (length o #1) commands) + 3
                val msg = String.concat "\n"
                                        (["<command> ...:", "", "Commands:"] @
                                         map (fn (cmd,(_,desc)) =>
                                                 "   " ^ cmd ^ repl (k-length cmd) " " ^ desc)
                                             commands)
            in usageMsg msg
            end
    in
      case eatFlags (CommandLine.arguments()) of
          cmd :: args => (case look cmd command of
                              SOME (doCmd,doc) => doCmd args
                            | NONE => usageMsg usage)
        | _ => doUsage()
    end

val () = main()
end