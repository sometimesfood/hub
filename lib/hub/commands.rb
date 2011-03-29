module Hub
  # See context.rb
  module Context; end

  # The Commands module houses the git commands that hub
  # lovingly wraps. If a method exists here, it is expected to have a
  # corresponding git command which either gets run before or after
  # the method executes.
  #
  # The typical flow is as follows:
  #
  # 1. hub is invoked from the command line:
  #    $ hub clone rtomayko/tilt
  #
  # 2. The Hub class is initialized:
  #    >> hub = Hub.new('clone', 'rtomayko/tilt')
  #
  # 3. The method representing the git subcommand is executed with the
  #    full args:
  #    >> Commands.clone('clone', 'rtomayko/tilt')
  #
  # 4. That method rewrites the args as it sees fit:
  #    >> args[1] = "git://github.com/" + args[1] + ".git"
  #    => "git://github.com/rtomayko/tilt.git"
  #
  # 5. The new args are used to run `git`:
  #    >> exec "git", "clone", "git://github.com/rtomayko/tilt.git"
  #
  # An optional `after` callback can be set. If so, it is run after
  # step 5 (which then performs a `system` call rather than an
  # `exec`). See `Hub::Args` for more information on the `after` callback.
  module Commands
    # We are a blank slate.
    instance_methods.each { |m| undef_method(m) unless m =~ /(^__|send|to\?$)/ }
    extend self

    # Provides `github_url` and various inspection methods
    extend Context

    API_REPO   = 'http://github.com/api/v2/yaml/repos/show/%s/%s'
    API_FORK   = 'http://github.com/api/v2/yaml/repos/fork/%s/%s'
    API_CREATE = 'http://github.com/api/v2/yaml/repos/create'

    def run(args)
      # Hack to emulate git-style
      args.unshift 'help' if args.grep(/^[^-]|version|exec-path$|html-path/).empty?

      cmd = args[0]
      expanded_args = expand_alias(cmd)
      cmd = expanded_args[0] if expanded_args

      # git commands can have dashes
      cmd = cmd.sub(/(\w)-/, '\1_')
      if method_defined?(cmd) and cmd != 'run'
        args[0, 1] = expanded_args if expanded_args
        send(cmd, args)
      end
    end

    # $ hub clone rtomayko/tilt
    # > git clone git://github.com/rtomayko/tilt.
    #
    # $ hub clone -p kneath/hemingway
    # > git clone git@github.com:kneath/hemingway.git
    #
    # $ hub clone tilt
    # > git clone git://github.com/YOUR_LOGIN/tilt.
    #
    # $ hub clone -p github
    # > git clone git@github.com:YOUR_LOGIN/hemingway.git
    def clone(args)
      ssh = args.delete('-p')
      has_values = /^(--(upload-pack|template|depth|origin|branch|reference)|-[ubo])$/

      idx = 1
      while idx < args.length
        arg = args[idx]
        if arg.index('-') == 0
          idx += 1 if arg =~ has_values
        elsif arg.index('://') or arg.index('@') or File.directory?(arg)
          # Bail out early for URLs and local paths.
          break
        elsif arg.scan('/').size <= 1 && !arg.include?(':')
          # $ hub clone rtomayko/tilt
          # $ hub clone tilt
          args[args.index(arg)] = github_url(:repo => arg, :private => ssh)
          break
        end
        idx += 1
      end
    end

    # $ hub submodule add wycats/bundler vendor/bundler
    # > git submodule add git://github.com/wycats/bundler.git vendor/bundler
    #
    # $ hub submodule add -p wycats/bundler vendor/bundler
    # > git submodule add git@github.com:wycats/bundler.git vendor/bundler
    #
    # $ hub submodule add -b ryppl ryppl/pip vendor/bundler
    # > git submodule add -b ryppl git://github.com/ryppl/pip.git vendor/pip
    def submodule(args)
      return unless index = args.index('add')
      args.delete_at index

      branch = args.index('-b') || args.index('--branch')
      if branch
        args.delete_at branch
        branch_name = args.delete_at branch
      end

      clone(args)

      if branch_name
        args.insert branch, '-b', branch_name
      end
      args.insert index, 'add'
    end

    # $ hub remote add pjhyett
    # > git remote add pjhyett git://github.com/pjhyett/THIS_REPO.git
    #
    # $ hub remote add -p mojombo
    # > git remote add mojombo git@github.com:mojombo/THIS_REPO.git
    #
    # $ hub remote add origin
    # > git remote add origin git://github.com/YOUR_LOGIN/THIS_REPO.git
    def remote(args)
      return unless ['add','set-url'].include?(args[1]) && args.last !~ %r{.+?://|.+?@|^[./]}

      ssh = args.delete('-p')

      # user/repo
      args.last =~ /\b(.+?)(?:\/(.+))?$/
      user, repo = $1, $2

      if args.words[2] == 'origin' && args.words[3].nil?
        # Origin special case triggers default user/repo
        user = repo = nil
      elsif args.words[-2] == args.words[1]
        # rtomayko/tilt => rtomayko
        # Make sure you dance around flags.
        idx = args.index( args.words[-1] )
        args[idx] = user
      else
        # They're specifying the remote name manually (e.g.
        # git remote add blah rtomayko/tilt), so just drop the last
        # argument.
        args.replace args[0...-1]
      end

      args << github_url(:user => user, :repo => repo, :private => ssh)
    end

    # $ hub fetch mislav
    # > git remote add mislav git://github.com/mislav/REPO.git
    # > git fetch mislav
    #
    # $ hub fetch --multiple mislav xoebus
    # > git remote add mislav ...
    # > git remote add xoebus ...
    # > git fetch --multiple mislav xoebus
    def fetch(args)
      # $ hub fetch --multiple <name1>, <name2>, ...
      if args.include?('--multiple')
        names = args.words[1..-1]
      # $ hub fetch <name>
      elsif remote_name = args.words[1]
        # $ hub fetch <name1>,<name2>,...
        if remote_name =~ /^\w+(,\w+)+$/
          index = args.index(remote_name)
          args.delete(remote_name)
          names = remote_name.split(',')
          args.insert(index, *names)
          args.insert(index, '--multiple')
        else
          names = [remote_name]
        end
      else
        names = []
      end

      names.reject! { |name|
        name =~ /\W/ or remotes.include?(name) or
          remotes_group(name) or not repo_exists?(name)
      }

      if names.any?
        names.each do |name|
          args.before ['remote', 'add', name, github_url(:user => name)]
        end
      end
    end

    # $ git cherry-pick http://github.com/mislav/hub/commit/a319d88#comments
    # > git remote add -f mislav git://github.com/mislav/hub.git
    # > git cherry-pick a319d88
    #
    # $ git cherry-pick mislav@a319d88
    # > git remote add -f mislav git://github.com/mislav/hub.git
    # > git cherry-pick a319d88
    #
    # $ git cherry-pick mislav@SHA
    # > git fetch mislav
    # > git cherry-pick SHA
    def cherry_pick(args)
      unless args.include?('-m') or args.include?('--mainline')
        case ref = args.words.last
        when %r{^(?:https?:)//github.com/(.+?)/(.+?)/commit/([a-f0-9]{7,40})}
          user, repo, sha = $1, $2, $3
          args[args.index(ref)] = sha
        when /^(\w+)@([a-f1-9]{7,40})$/
          user, repo, sha = $1, nil, $2
          args[args.index(ref)] = sha
        else
          user = nil
        end

        if user
          if user == repo_owner
            # fetch from origin if the repo belongs to the user
            args.before ['fetch', default_remote]
          elsif remotes.include?(user)
            args.before ['fetch', user]
          else
            remote_url = github_url(:user => user, :repo => repo, :private => false)
            args.before ['remote', 'add', '-f', user, remote_url]
          end
        end
      end
    end

    # $ hub am https://github.com/defunkt/hub/pull/55
    # > curl https://github.com/defunkt/hub/pull/55.patch -o /tmp/55.patch
    # > git am /tmp/55.patch
    def am(args)
      if url = args.find { |a| a =~ %r{^https?://(gist\.)?github\.com/} }
        idx = args.index(url)
        gist = $1 == 'gist.'
        # strip extra path from "pull/42/files", "pull/42/commits"
        url = url.sub(%r{(/pull/\d+)/\w*$}, '\1') unless gist
        ext = gist ? '.txt' : '.patch'
        url += ext unless File.extname(url) == ext
        patch_file = File.join(ENV['TMPDIR'], "#{gist ? 'gist-' : ''}#{File.basename(url)}")
        args.before 'curl', ['-#LA', "hub #{Hub::Version}", url, '-o', patch_file]
        args[idx] = patch_file
      end
    end

    # $ hub init -g
    # > git init
    # > git remote add origin git@github.com:USER/REPO.git
    def init(args)
      if args.delete('-g')
        url = github_url(:private => true, :repo => current_dirname)
        args.after "git remote add origin #{url}"
      end
    end

    # $ hub fork
    # ... hardcore forking action ...
    # > git remote add -f YOUR_USER git@github.com:YOUR_USER/CURRENT_REPO.git
    def fork(args)
      # can't do anything without token and original owner name
      if github_user && github_token && repo_owner
        if repo_exists?(github_user)
          puts "#{github_user}/#{repo_name} already exists on GitHub"
        else
          fork_repo
        end

        if args.include?('--no-remote')
          exit
        else
          url = github_url(:private => true)
          args.replace %W"remote add -f #{github_user} #{url}"
          args.after { puts "new remote: #{github_user}" }
        end
      end
    rescue Net::HTTPExceptions
      response = $!.response
      warn "error creating fork: #{response.message} (HTTP #{response.code})"
      exit 1
    end

    # $ hub create
    # ... create repo on github ...
    # > git remote add -f origin git@github.com:YOUR_USER/CURRENT_REPO.git
    def create(args)
      if !is_repo?
        puts "'create' must be run from inside a git repository"
        args.skip!
      elsif github_user && github_token
        args.shift
        options = {}
        options[:private] = true if args.delete('-p')

        until args.empty?
          case arg = args.shift
          when '-d'
            options[:description] = args.shift
          when '-h'
            options[:homepage] = args.shift
          else
            puts "unexpected argument: #{arg}"
            return
          end
        end

        if repo_exists?(github_user)
          puts "#{github_user}/#{repo_name} already exists on GitHub"
          action = "set remote origin"
        else
          action = "created repository"
          create_repo(options)
        end

        url = github_url(:private => true)

        if remotes.first != 'origin'
          args.replace %W"remote add -f origin #{url}"
        else
          args.replace %W"remote -v"
        end

        args.after { puts "#{action}: #{github_user}/#{repo_name}" }
      end
    rescue Net::HTTPExceptions
      response = $!.response
      warn "error creating repository: #{response.message} (HTTP #{response.code})"
      exit 1
    end

    # $ hub push origin,staging cool-feature
    # > git push origin cool-feature
    # > git push staging cool-feature
    def push(args)
      return unless args[1] =~ /,/

      branch  = args[2]
      remotes = args[1].split(',')
      args[1] = remotes.shift

      remotes.each do |name|
        args.after ['push', name, branch]
      end
    end

    # $ hub browse
    # > open https://github.com/CURRENT_REPO
    #
    # $ hub browse -- issues
    # > open https://github.com/CURRENT_REPO/issues
    #
    # $ hub browse pjhyett/github-services
    # > open https://github.com/pjhyett/github-services
    #
    # $ hub browse github-services
    # > open https://github.com/YOUR_LOGIN/github-services
    #
    # $ hub browse github-services wiki
    # > open https://github.com/YOUR_LOGIN/github-services/wiki
    def browse(args)
      args.shift
      browse_command(args) do
        user = repo = nil
        dest = args.shift
        dest = nil if dest == '--'

        if dest
          # $ hub browse pjhyett/github-services
          # $ hub browse github-services
          repo = dest
        elsif repo_user
          # $ hub browse
          user = repo_user
        else
          abort "Usage: hub browse [<USER>/]<REPOSITORY>"
        end

        params = { :user => user, :repo => repo }

        # $ hub browse -- wiki
        case subpage = args.shift
        when 'commits'
          branch = (!dest && tracked_branch) || 'master'
          params[:web] = "/commits/#{branch}"
        when 'tree', NilClass
          branch = !dest && tracked_branch
          params[:web] = "/tree/#{branch}" if branch && branch != 'master'
        else
          params[:web] = "/#{subpage}"
        end

        params
      end
    end

    # $ hub compare 1.0...fix
    # > open https://github.com/CURRENT_REPO/compare/1.0...fix
    # $ hub compare refactor
    # > open https://github.com/CURRENT_REPO/compare/refactor
    # $ hub compare myfork feature
    # > open https://github.com/myfork/REPO/compare/feature
    # $ hub compare -u 1.0...2.0
    # "https://github.com/CURRENT_REPO/compare/1.0...2.0"
    def compare(args)
      args.shift
      browse_command(args) do
        if args.empty?
          branch = tracked_branch
          if branch && branch != 'master'
            range, user = branch, repo_user
          else
            abort "Usage: hub compare [USER] [<START>...]<END>"
          end
        else
          range = args.pop
          user = args.pop || repo_user
        end
        { :user => user, :web => "/compare/#{range}" }
      end
    end

    # $ hub hub standalone
    # Prints the "standalone" version of hub for an easy, memorable
    # installation sequence:
    #
    # $ gem install hub
    # $ hub hub standalone > ~/bin/hub && chmod 755 ~/bin/hub
    # $ gem uninstall hub
    def hub(args)
      return help(args) unless args[1] == 'standalone'
      require 'hub/standalone'
      puts Hub::Standalone.build
      exit
    rescue LoadError
      abort "hub is running in standalone mode."
    end

    def alias(args)
      shells = {
        'sh'   => 'alias git=hub',
        'bash' => 'alias git=hub',
        'zsh'  => 'function git(){hub "$@"}',
        'csh'  => 'alias git hub',
        'fish' => 'alias git hub'
      }

      silent = args.delete('-s')

      if shell = args[1]
        if silent.nil?
          puts "Run this in your shell to start using `hub` as `git`:"
          print "  "
        end
      else
        puts "usage: hub alias [-s] SHELL", ""
        puts "You already have hub installed and available in your PATH,"
        puts "but to get the full experience you'll want to alias it to"
        puts "`git`.", ""
        puts "To see how to accomplish this for your shell, run the alias"
        puts "command again with the name of your shell.", ""
        puts "Known shells:"
        shells.map { |key, _| key }.sort.each do |key|
          puts "  " + key
        end
        puts "", "Options:"
        puts "  -s   Silent. Useful when using the output with eval, e.g."
        puts "       $ eval `hub alias -s bash`"

        exit
      end

      if shells[shell]
        puts shells[shell]
      else
        abort "fatal: never heard of `#{shell}'"
      end

      exit
    end

    # $ hub version
    # > git version
    # (print hub version)
    def version(args)
      args.after do
        puts "hub version %s" % Version
      end
    end
    alias_method "--version", :version

    # $ hub help
    # (print improved help text)
    def help(args)
      command = args.grep(/^[^-]/)[1]

      if command == 'hub'
        puts hub_manpage
        exit
      elsif command.nil? && args.grep(/^--?a/).empty?
        ENV['GIT_PAGER'] = '' if args.grep(/^-{1,2}p/).empty? # Use `cat`.
        puts improved_help_text
        exit
      end
    end
    alias_method "--help", :help

    # The text print when `hub help` is run, kept in its own method
    # for the convenience of the author.
    def improved_help_text
      <<-help
usage: git [--version] [--exec-path[=GIT_EXEC_PATH]] [--html-path]
    [-p|--paginate|--no-pager] [--bare] [--git-dir=GIT_DIR]
    [--work-tree=GIT_WORK_TREE] [--help] COMMAND [ARGS]

Basic Commands:
   init       Create an empty git repository or reinitialize an existing one
   add        Add new or modified files to the staging area
   rm         Remove files from the working directory and staging area
   mv         Move or rename a file, a directory, or a symlink
   status     Show the status of the working directory and staging area
   commit     Record changes to the repository

History Commands:
   log        Show the commit history log
   diff       Show changes between commits, commit and working tree, etc
   show       Show information about commits, tags or files

Branching Commands:
   branch     List, create, or delete branches
   checkout   Switch the active branch to another branch
   merge      Join two or more development histories (branches) together
   tag        Create, list, delete, sign or verify a tag object

Remote Commands:
   clone      Clone a remote repository into a new directory
   fetch      Download data, tags and branches from a remote repository
   pull       Fetch from and merge with another repository or a local branch
   push       Upload data, tags and branches to a remote repository
   remote     View and manage a set of remote repositories

Advanced commands:
   reset      Reset your staging area or working directory to another point
   rebase     Re-apply a series of patches in one branch onto another
   bisect     Find by binary search the change that introduced a bug
   grep       Print files with lines matching a pattern in your codebase

See 'git help COMMAND' for more information on a specific command.
help
    end

  private
    #
    # Helper methods are private so they cannot be invoked
    # from the command line.
    #

    # Checks whether a command exists on this system in the $PATH.
    #
    # name - The String name of the command to check for.
    #
    # Returns a Boolean.
    def command?(name)
      `which #{name} 2>/dev/null`
      $?.success?
    end

    # Detects commands to launch the user's browser, checking $BROWSER
    # first then falling back to a few common launchers. Aborts with
    # an error if it can't find anything appropriate.
    #
    # Returns a launch command.
    def browser_launcher
      if ENV['BROWSER']
        ENV['BROWSER']
      elsif RUBY_PLATFORM.include?('darwin')
        "open"
      elsif command?("xdg-open")
        "xdg-open"
      elsif command?("cygstart")
        "cygstart"
      else
        abort "Please set $BROWSER to a web launcher to use this command."
      end
    end

    # Handles common functionality of browser commands like `browse`
    # and `compare`. Yields a block that returns params for `github_url`.
    def browse_command(args)
      url_only = args.delete('-u')
      $stderr.puts "Warning: the `-p` flag has no effect anymore" if args.delete('-p')
      params = yield

      args.executable = url_only ? 'echo' : browser_launcher
      args.push github_url({:web => true, :private => true}.update(params))
    end


    # Returns the terminal-formatted manpage, ready to be printed to
    # the screen.
    def hub_manpage
      return "** Can't find groff(1)" unless command?('groff')

      require 'open3'
      out = nil
      Open3.popen3(groff_command) do |stdin, stdout, _|
        stdin.puts hub_raw_manpage
        stdin.close
        out = stdout.read.strip
      end
      out
    end

    # The groff command complete with crazy arguments we need to run
    # in order to turn our raw roff (manpage markup) into something
    # readable on the terminal.
    def groff_command
      "groff -Wall -mtty-char -mandoc -Tascii"
    end

    # Returns the raw hub manpage. If we're not running in standalone
    # mode, it's a file sitting at the root under the `man`
    # directory.
    #
    # If we are running in standalone mode the manpage will be
    # included after the __END__ of the file so we can grab it using
    # DATA.
    def hub_raw_manpage
      if File.exists? file = File.dirname(__FILE__) + '/../../man/hub.1'
        File.read(file)
      else
        DATA.read
      end
    end

    # All calls to `puts` in after hooks or commands are paged,
    # git-style.
    def puts(*args)
      page_stdout
      super
    end

    # http://nex-3.com/posts/73-git-style-automatic-paging-in-ruby
    def page_stdout
      return unless $stdout.tty?

      read, write = IO.pipe

      if Kernel.fork
        # Parent process, become pager
        $stdin.reopen(read)
        read.close
        write.close

        # Don't page if the input is short enough
        ENV['LESS'] = 'FSRX'

        # Wait until we have input before we start the pager
        Kernel.select [STDIN]

        pager = ENV['GIT_PAGER'] ||
          `git config --get-all core.pager`.split.first || ENV['PAGER'] ||
          'less -isr'

        pager = 'cat' if pager.empty?

        exec pager rescue exec "/bin/sh", "-c", pager
      else
        # Child process
        $stdout.reopen(write)
        $stderr.reopen(write) if $stderr.tty?
        read.close
        write.close
      end
    end

    # Determines whether a user has a fork of the current repo on GitHub.
    def repo_exists?(user)
      require 'net/http'
      url = API_REPO % [user, repo_name]
      Net::HTTPSuccess === Net::HTTP.get_response(URI(url))
    end

    # Forks the current repo using the GitHub API.
    #
    # Returns nothing.
    def fork_repo
      url = API_FORK % [repo_owner, repo_name]
      response = Net::HTTP.post_form(URI(url), 'login' => github_user, 'token' => github_token)
      response.error! unless Net::HTTPSuccess === response
    end

    # Creates a new repo using the GitHub API.
    #
    # Returns nothing.
    def create_repo(options = {})
      url = API_CREATE
      params = {'login' => github_user, 'token' => github_token, 'name' => repo_name}
      params['public'] = '0' if options[:private]
      params['description'] = options[:description] if options[:description]
      params['homepage'] = options[:homepage] if options[:homepage]

      response = Net::HTTP.post_form(URI(url), params)
      response.error! unless Net::HTTPSuccess === response
    end

    def expand_alias(cmd)
      if expanded = git_alias_for(cmd)
        if expanded.index('!') != 0
          require 'shellwords' unless expanded.respond_to? :shellsplit
          expanded.shellsplit
        end
      end
    end

  end
end
