import std/[os, osproc, sequtils, strutils, options]
import context, osutils

type
  Command* = enum
    GitClone = "git clone",
    GitDiff = "git diff",
    GitFetch = "git fetch",
    GitTag = "git tag",
    GitTags = "git show-ref --tags",
    GitLastTaggedRef = "git rev-list --tags --max-count=1",
    GitDescribe = "git describe",
    GitRevParse = "git rev-parse",
    GitCheckout = "git checkout",
    GitSubModUpdate = "git submodule update --init",
    GitPush = "git push origin",
    GitPull = "git pull",
    GitCurrentCommit = "git log -n 1 --format=%H"
    GitMergeBase = "git merge-base"
    GitLsFiles = "git -C $1 ls-files",

proc isGitDir*(path: string): bool =
  let gitPath = path / ".git"
  dirExists(gitPath) or fileExists(gitPath)

proc sameVersionAs*(tag, ver: string): bool =
  const VersionChars = {'0'..'9', '.'}

  proc safeCharAt(s: string; i: int): char {.inline.} =
    if i >= 0 and i < s.len: s[i] else: '\0'

  let idx = find(tag, ver)
  if idx >= 0:
    # we found the version as a substring inside the `tag`. But we
    # need to watch out the the boundaries are not part of a
    # larger/different version number:
    result = safeCharAt(tag, idx-1) notin VersionChars and
      safeCharAt(tag, idx+ver.len) notin VersionChars

proc extractVersion*(s: string): string =
  var i = 0
  while i < s.len and s[i] notin {'0'..'9'}: inc i
  result = s.substr(i)

proc exec*(c: var AtlasContext;
           cmd: Command;
           args: openArray[string],
           execDir = ""): (string, int) =
  when MockupRun:
    assert TestLog[c.step].cmd == cmd, $(TestLog[c.step].cmd, cmd, c.step)
    case cmd
    of GitDiff, GitTag, GitTags, GitLastTaggedRef, GitDescribe, GitRevParse, GitPush, GitPull, GitCurrentCommit:
      result = (TestLog[c.step].output, TestLog[c.step].exitCode)
    of GitCheckout:
      assert args[0] == TestLog[c.step].output
    of GitMergeBase:
      let tmp = TestLog[c.step].output.splitLines()
      assert tmp.len == 4, $tmp.len
      assert tmp[0] == args[0]
      assert tmp[1] == args[1]
      assert tmp[3] == ""
      result[0] = tmp[2]
      result[1] = TestLog[c.step].exitCode
    inc c.step
  else:
    let cmd = if execDir.len() == 0: $cmd else: $(cmd) % [execDir]
    if isGitDir(if execDir.len() == 0: getCurrentDir() else: execDir):
      result = silentExec(cmd, args)
    else:
      result = ("not a git repository", 1)
    when ProduceTest:
      echo "cmd ", cmd, " args ", args, " --> ", result

proc checkGitDiffStatus*(c: var AtlasContext): Option[string] =
  let (outp, status) = exec(c, GitDiff, [])
  if outp.len != 0:
    some("'git diff' not empty")
  elif status != 0:
    some("'git diff' returned non-zero")
  else:
    none(string)

proc clone*(c: var AtlasContext, url: PackageUrl, dest: string, retries = 5): bool =
  ## clone git repo.
  ##
  ## note clones don't use `--recursive` but rely in the `checkoutCommit`
  ## stage to setup submodules as this is less fragile on broken submodules.
  ##

  # retry multiple times to avoid annoying github timeouts:
  let extraArgs =
    if FullClones notin c.flags: "--depth=1"
    else: ""

  for i in 1..retries:
    let cmd = $GitClone & " " & extraArgs & " " & quoteShell($url) & " " & dest
    if execShellCmd(cmd) == 0:
      return true
    os.sleep(i*2_000)

proc gitDescribeRefTag*(c: var AtlasContext; commit: string): string =
  let (lt, status) = exec(c, GitDescribe, ["--tags", commit])
  result = if status == 0: strutils.strip(lt) else: ""

proc getLastTaggedCommit*(c: var AtlasContext): string =
  let (ltr, status) = exec(c, GitLastTaggedRef, [])
  if status == 0:
    let lastTaggedRef = ltr.strip()
    let lastTag = gitDescribeRefTag(c, lastTaggedRef)
    if lastTag.len != 0:
      result = lastTag

proc collectTaggedVersions*(c: var AtlasContext): seq[Commit] =
  let (outp, status) = exec(c, GitTags, [])
  if status == 0:
    result = parseTaggedVersions(outp)
  else:
    result = @[]

proc versionToCommit*(c: var AtlasContext; d: Dependency): string =
  let allVersions = collectTaggedVersions(c)
  case d.algo
  of MinVer:
    result = selectBestCommitMinVer(allVersions, d.query)
  of SemVer:
    result = selectBestCommitSemVer(allVersions, d.query)
  of MaxVer:
    result = selectBestCommitMaxVer(allVersions, d.query)

proc shortToCommit*(c: var AtlasContext; short: string): string =
  let (cc, status) = exec(c, GitRevParse, [short])
  result = if status == 0: strutils.strip(cc) else: ""

proc listFiles*(c: var AtlasContext; pkg: Package): Option[seq[string]] =
  let (outp, status) = exec(c, GitLsFiles, [], pkg.path.string)
  if status == 0:
    result = some outp.splitLines().mapIt(it.strip())

proc checkoutGitCommit*(c: var AtlasContext; p: PackageDir; commit: string) =
  let p = p.string.PackageRepo
  var smExtraArgs: seq[string]

  if FullClones notin c.flags and commit.len() == 40:
    smExtraArgs.add "--depth=1"

    let (_, status) = exec(c, GitFetch, ["--update-shallow", "--tags", "origin", commit])
    if status != 0:
      error(c, p, "could not fetch commit " & commit)
    else:
      trace(c, p, "fetched package commit " & commit)
  elif commit.len() != 40:
    info(c, p, "found short commit id; doing full fetch to resolve " & commit)
    let (outp, status) = exec(c, GitFetch, ["--unshallow"])
    if status != 0:
      error(c, p, "could not fetch: " & outp)
    else:
      trace(c, p, "fetched package updates ")

  let (_, status) = exec(c, GitCheckout, [commit])
  if status != 0:
    error(c, p, "could not checkout commit " & commit)
  else:
    info(c, p, "updated package to " & commit)

  let (_, subModStatus) = exec(c, GitSubModUpdate, smExtraArgs)
  if subModStatus != 0:
    error(c, p, "could not update submodules")
  else:
    info(c, p, "updated submodules ")

proc gitPull*(c: var AtlasContext; p: PackageRepo) =
  let (outp, status) = exec(c, GitPull, [])
  if status != 0:
    debug c, p, "git pull error: \n" & outp.splitLines().mapIt("\n>>> " & it).join("")
    error(c, p, "could not 'git pull'")

proc gitTag*(c: var AtlasContext; tag: string) =
  let (_, status) = exec(c, GitTag, [tag])
  if status != 0:
    error(c, c.projectDir.PackageRepo, "could not 'git tag " & tag & "'")

proc pushTag*(c: var AtlasContext; tag: string) =
  let (outp, status) = exec(c, GitPush, [tag])
  if status != 0:
    error(c, c.projectDir.PackageRepo, "could not 'git push " & tag & "'")
  elif outp.strip() == "Everything up-to-date":
    info(c, c.projectDir.PackageRepo, "is up-to-date")
  else:
    info(c, c.projectDir.PackageRepo, "successfully pushed tag: " & tag)

proc incrementTag*(c: var AtlasContext; lastTag: string; field: Natural): string =
  var startPos =
    if lastTag[0] in {'0'..'9'}: 0
    else: 1
  var endPos = lastTag.find('.', startPos)
  if field >= 1:
    for i in 1 .. field:
      if endPos == -1:
        error c, projectFromCurrentDir(), "the last tag '" & lastTag & "' is missing . periods"
        return ""
      startPos = endPos + 1
      endPos = lastTag.find('.', startPos)
  if endPos == -1:
    endPos = len(lastTag)
  let patchNumber = parseInt(lastTag[startPos..<endPos])
  lastTag[0..<startPos] & $(patchNumber + 1) & lastTag[endPos..^1]

proc incrementLastTag*(c: var AtlasContext; field: Natural): string =
  let (ltr, status) = exec(c, GitLastTaggedRef, [])
  if status == 0:
    let
      lastTaggedRef = ltr.strip()
      lastTag = gitDescribeRefTag(c, lastTaggedRef)
      currentCommit = exec(c, GitCurrentCommit, [])[0].strip()

    if lastTaggedRef == currentCommit:
      info c, c.projectDir.PackageRepo, "the current commit '" & currentCommit & "' is already tagged '" & lastTag & "'"
      lastTag
    else:
      incrementTag(c, lastTag, field)
  else: "v0.0.1" # assuming no tags have been made yet

proc needsCommitLookup*(commit: string): bool {.inline.} =
  '.' in commit or commit == InvalidCommit

proc isShortCommitHash*(commit: string): bool {.inline.} =
  commit.len >= 4 and commit.len < 40

proc getRequiredCommit*(c: var AtlasContext; w: Dependency): string =
  if needsCommitLookup(w.commit): versionToCommit(c, w)
  elif isShortCommitHash(w.commit): shortToCommit(c, w.commit)
  else: w.commit

proc getRemoteUrl*(): PackageUrl =
  execProcess("git config --get remote.origin.url").strip().getUrl()

proc getCurrentCommit*(): string =
  result = execProcess("git log -1 --pretty=format:%H").strip()

proc isOutdated*(c: var AtlasContext; path: PackageDir): bool =
  ## determine if the given git repo `f` is updateable
  ##

  info c, toRepo(path), "checking is package is up to date..."

  # TODO: does --update-shallow fetch tags on a shallow repo?
  let (outp, status) = exec(c, GitFetch, ["--update-shallow", "--tags"])

  if status == 0:
    let (cc, status) = exec(c, GitLastTaggedRef, [])
    let latestVersion = strutils.strip(cc)
    if status == 0 and latestVersion.len > 0:
      # see if we're past that commit:
      let (cc, status) = exec(c, GitCurrentCommit, [])
      if status == 0:
        let currentCommit = strutils.strip(cc)
        if currentCommit != latestVersion:
          # checkout the later commit:
          # git merge-base --is-ancestor <commit> <commit>
          let (cc, status) = exec(c, GitMergeBase, [currentCommit, latestVersion])
          let mergeBase = strutils.strip(cc)
          #if mergeBase != latestVersion:
          #  echo f, " I'm at ", currentCommit, " release is at ", latestVersion, " merge base is ", mergeBase
          if status == 0 and mergeBase == currentCommit:
            let v = extractVersion gitDescribeRefTag(c, latestVersion)
            if v.len > 0:
              info c, toRepo(path), "new version available: " & v
              result = true
  else:
    warn c, toRepo(path), "`git fetch` failed: " & outp

proc updateDir*(c: var AtlasContext; file, filter: string) =
  withDir c, file:
    let pkg = PackageRepo(file)
    let (remote, _) = osproc.execCmdEx("git remote -v")
    if filter.len == 0 or filter in remote:
      let diff = checkGitDiffStatus(c)
      if diff.isSome():
        warn(c, pkg, "has uncommitted changes; skipped")
      else:
        let (branch, _) = osproc.execCmdEx("git rev-parse --abbrev-ref HEAD")
        if branch.strip.len > 0:
          let (output, exitCode) = osproc.execCmdEx("git pull origin " & branch.strip)
          if exitCode != 0:
            error c, pkg, output
          else:
            info(c, pkg, "successfully updated")
        else:
          error c, pkg, "could not fetch current branch name"
