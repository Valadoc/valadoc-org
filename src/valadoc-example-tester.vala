public class ExampleTester : ExampleParser {
	private FileStream current_log;
	private string current_output_dir;
	private string current_log_path;
	private string current_basedir;
	public int errors { private set; get; default = 0; }
	private int example_errors = 0;
	private bool example_experimental;
	private bool example_deprecated;
	private bool keep_running;

	public ExampleTester (bool keep_running) {
		this.keep_running = keep_running;
	}

	private void report_warning (string msg) {
		stdout.puts ("warning: ");
		stdout.puts (build_error_message (msg));
		stdout.putc ('\n');
	}

	private void report_error (string msg, bool fatal = false) throws MarkupError {
		if (keep_running == false || fatal == true) {
			current_log = null;
			throw new MarkupError.INVALID_CONTENT (build_error_message (msg));
		} else {
			stdout.puts ("error: ");
			stdout.puts (build_error_message (msg));
			stdout.putc ('\n');
		}
	}

	protected override void example_start (bool deprecated, bool experimental) throws MarkupError {
		example_experimental = experimental;
		example_deprecated = deprecated;
		example_errors = 0;
		current_basedir = this.get_base_dir ();

		string pkg_name = Path.get_basename (filename.substring (0, filename.length - 17) + "--" + pos_as_string ());
		current_output_dir = Path.build_filename (Environment.get_current_dir (), "tmp", pkg_name);
		if (DirUtils.create (current_output_dir, 0777) == -1) {
			report_error (strerror (errno), true);
		}

		current_log_path = Path.build_filename (current_output_dir, "LOG");
		current_log = FileStream.open (current_log_path, "w");
		if (current_log == null) {
			report_error (strerror (errno), true);
		}
	}

	protected override void file (string file) throws MarkupError {
		string file_name = Path.get_basename (file);
		string dest = Path.build_filename (current_output_dir, file_name);
		if (copy_file (file, dest) == false) {
			report_error ("can't copy %s to %s".printf (file, dest), true);
		}
	}

	protected override void compile (string str) throws MarkupError {
		string cmnd = str.strip ();

		const string VALAC_PREFIX = "valac ";
		bool is_valac_call = str.has_prefix (VALAC_PREFIX);
		bool is_schema_call = str.has_prefix ("glib-compile-schemas");

		// We only check for sanity, not for safety
		if (is_valac_call == false && is_schema_call == false) {
			report_warning ("not a valac- or glib-compile-schemas-call, ignored");
			return ;
		}

		if (is_valac_call) {
			cmnd = Environment.get_variable ("VALAC") + " " +
				cmnd.substring (VALAC_PREFIX.length);
			cmnd += " --fatal-warnings";
			if (example_deprecated == true) {
				cmnd += " --enable-deprecated";
			}
			if (example_experimental == true) {
				cmnd += " --enable-experimental";
			}
		}

		try {
			int exit_status = 0;
			string? standard_output = null;
			string? standard_error = null;
			string[] argv;

			if (Shell.parse_argv (cmnd, out argv) == false) {
				report_error ("parse_argv failed");
				example_errors++;
				errors++;
				return ;
			}

			Process.spawn_sync (current_output_dir, argv, Environ.get (), SpawnFlags.SEARCH_PATH, null, out standard_output, out standard_error, out exit_status);
			current_log.puts (cmnd);
			current_log.putc ('\n');
			current_log.printf ("Exit status: %d\n", exit_status);
			current_log.puts ("Stderr:\n");
			current_log.puts (standard_error);
			current_log.putc ('\n');
			current_log.puts ("Stdout:\n");
			current_log.puts (standard_output);
			current_log.putc ('\n');
			current_log.puts ("-------------\n");

			if (exit_status != 0) {
				// errors are reported in example_end ()
				// to run the whole example
				example_errors++;
				errors++;
			}
		} catch (Error e) {
			current_log.puts (cmnd);
			current_log.puts (e.message);
			current_log.putc ('\n');
			report_error (e.message);
		}
	}

	protected override void example_end () throws MarkupError {
		current_log = null;
		if (example_errors == 0) {
			string errmsg;
			rmdir_r (current_output_dir, out errmsg);
			if (errmsg != null) {
				report_error (errmsg);
			}
		} else {
			report_error ("An error occurred. Please check the logs.");
		}

		example_experimental = false;
		example_deprecated = false;
		current_log_path = null;
		current_output_dir = null;
		current_basedir = null;
		example_errors = 0;
	}

	public static int main (string[] _args) {
		// We can't set members to null otherwise
		string[] args = _args;

		// Check all arguments:
		if (args.length == 1) {
			stdout.printf ("%s [--keep-running|--force] FILE...\n", args[0]);
			return -1;
		}

		bool keep_running = false;
		bool force = false;
		for (int i = 1; i < args.length; i++) {
			switch (args[i]) {
			case "--keep-running":
				keep_running = true;
				args[i] = null;
				break;
			case "--force":
				force = true;
				args[i] = null;
				break;
			case "--help":
				stdout.printf ("%s:\n", args[0]);
				stdout.puts ("  --keep-running    Do not stop on compiler errors\n");
				stdout.puts ("  --force           Override existing tmp/ dirs\n");
				stdout.puts ("  --help            Show help options\n");
				return 0;
			}
		}

		for (int i = 1; i < args.length; i++) {
			if (args[i] == null) {
				continue ;
			}

			if (args[i].has_suffix (".valadoc.examples") == false) {
				stdout.printf ("error: %s is not a .valadoc.examples file\n", args[i]);
				return -1;
			}

			if (FileUtils.test (args[i], FileTest.EXISTS) == false) {
				stdout.printf ("error: %s does not exist\n", args[i]);
				return -1;
			}

			if (FileUtils.test (args[i], FileTest.IS_REGULAR) == false) {
				stdout.printf ("error: %s is not a regular file\n", args[i]);
				return -1;
			}
		}

		if (force == true) {
			rmdir_r ("tmp/");
		}

		// Run:
		if (DirUtils.create ("tmp", 0777) == -1) {
			stdout.printf ("error: %s\n", strerror (errno));
			return -1;
		}

		ExampleTester parser = new ExampleTester (keep_running);
		for (int i = 1; i < args.length; i++) {
			if (args[i] == null) {
				continue ;
			}

			try {
				parser.parse (args[i]);
			} catch (Error e) {
				stdout.printf ("error: %s\n", e.message);
				if (keep_running == false) {
					break;
				}
			}
		}

		DirUtils.remove ("tmp");
		return (parser.errors == 0)? 0 : -1;
	}

	private static bool copy_file (string src, string dest) {
		FileStream fsrc = FileStream.open (src, "rb");
		if (fsrc == null) {
			return false;
		}

		FileStream fdest = FileStream.open (dest, "wb");
		if (fdest == null) {
			return false;
		}

		for (int c = fsrc.getc() ; !fsrc.eof(); c = fsrc.getc()) {
			fdest.putc ((char)c);
		}

		return true;
	}

	private static bool rmdir_r (string rpath, out string errmsg = null) {
		errmsg = null;
		try {
			Dir dir = Dir.open (rpath);
			if (dir == null) {
				errmsg = rpath + ": " + strerror (errno);
				return false;
			}

			for (weak string entry = dir.read_name(); entry != null ; entry = dir.read_name()) {
				string path = Path.build_filename (rpath, entry);

				bool is_dir = FileUtils.test (path, FileTest.IS_DIR);
				if (is_dir == true) {
					bool tmp = rmdir_r (path, out errmsg);
					if (tmp == false) {
						assert (errmsg != null);
						return false;
					}
				} else {
					int tmp = FileUtils.unlink (path);
					if (tmp == -1) {
						errmsg = path + ": " + strerror (errno);
						return false;
					}
				}
			}

			int tmp = DirUtils.remove (rpath);
			if (tmp == -1) {
				errmsg = rpath + ": " + strerror (errno);
				return false;
			}
		} catch (FileError err) {
			errmsg = rpath + ": " + strerror (errno);
			return false;
		}

		return true;
	}
}
