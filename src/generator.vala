/* generator.vala
 *
 * Copyright (C) 2012-2013  Florian Brosch
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 *
 * Author:
 * 	Florian Brosch <flo.brosch@gmail.com>
 */


//
// This code is not supposed to be good. It's just a dirty script to reduce my work.
// Feel free to decrease the code quality even more.
//


public class Valadoc.IndexGenerator : Valadoc.ValadocOrgDoclet {
	private Gee.LinkedList<Package> unavailable_packages = new Gee.LinkedList<Package> ();
	private Gee.HashMap<string, Package> packages_per_name = new Gee.HashMap<string, Package> ();
	private Gee.Collection<Node> sections;
	private Regex markdown_img_regex;
	private string global_wget_flags = "--no-verbose";

	private bool has_error = false;

	private void print_stored_messages () {
		foreach (Package pkg in unavailable_packages) {
			reporter.simple_warning (null, "error: Package '%s' not found", pkg.name);
		}
	}

	private void register_package (Section? section, Package pkg) {
		packages_per_name.set (pkg.name, pkg);
		if (section != null) {
			section.packages.add (pkg);
		}
	}

	private static string[] get_vapi_directories () {
		int exit_status = 0;
		string? standard_output = null;
		string? standard_error = null;
		string[] paths = new string[0];


		// Unversioned vapi directory:
		try {
			Process.spawn_command_line_sync ("pkg-config --variable=vapidir vapigen-%s".printf (Vala.API_VERSION), out standard_output, out standard_error, out exit_status);
			if (exit_status == 0) {
				paths += standard_output.strip ();
			}
		} catch (Error e) {
		}


		// Versioned vapi directory:
		try {
			Process.spawn_command_line_sync ("pkg-config --variable=vapidir libvala-%s".printf (Vala.API_VERSION), out standard_output, out standard_error, out exit_status);
			if (exit_status == 0) {
				paths += standard_output.strip ();
			}
		} catch (Error e) {
		}

		return paths;
	}


	[CCode (array_length = false, array_null_terminated = true)]
	private static string[] requested_packages;
	private static bool regenerate_all_packages;
	private static string output_directory;
	private static string metadata_path;
	private static string docletpath;
	private static bool download_images;
	private static string prefix;
	private static bool skip_existing;
	private static string girdir = "girs/gir-1.0";
	private static string target_glib;
	private static bool wget_no_check_certificate;
	private static bool disable_devhelp;
	[CCode (array_length = false, array_null_terminated = true)]
	private static string[] vapidirs;

	public IndexGenerator (ErrorReporter reporter) {
		this.global_wget_flags += wget_no_check_certificate ? " --no-check-certificate" : "";
		this.reporter = new ErrorReporter ();

		// TODO: += is broken for LHS array_length = false
		//foreach (string dir in get_vapi_directories ()) {
		//	vapidirs += dir;
		//}
		string[] tmp_vapidirs = vapidirs;
		foreach (string dir in get_vapi_directories ()) {
			tmp_vapidirs += dir;
		}
		vapidirs = tmp_vapidirs;

		try {
			string label = "([^(\\]\n)](\n[ \t]*)?)*";
			string path = "(?<img>([^(\\)|\n)])*)";
			markdown_img_regex = new Regex ("!\\[" + label + "\\][ \t]*\n?[ \t]*\\(" + path + "\\)", RegexCompileFlags.UNGREEDY | RegexCompileFlags.OPTIMIZE);
		} catch (RegexError e) {
			error (e.message);
		}
	}

	private const GLib.OptionEntry[] options = {
		{ "prefix", 0, 0, OptionArg.STRING, ref prefix, "package prefix (e.g. stable, unstable)", null},
		{ "all", 0, 0, OptionArg.NONE, ref regenerate_all_packages, "Regenerate documentation for all packages", null },
		{ "directory", 'o', 0, OptionArg.FILENAME, ref output_directory, "Output directory", "DIRECTORY" },
		{ "target-glib", 0, 0, OptionArg.STRING, ref target_glib, "Target version of glib for code generation", "MAJOR.MINOR" },
		{ "download-images", 0, 0, OptionArg.NONE, ref download_images, "Download images", null },
		{ "doclet", 0, 0, OptionArg.STRING, ref docletpath, "Name of an included doclet or path to custom doclet", "PLUGIN"},
		{ "vapidir", 0, 0, OptionArg.FILENAME_ARRAY, ref vapidirs, "Look for package bindings in DIRECTORY", "[DIRECTORY]"},
		{ "skip-existing", 0, 0, OptionArg.NONE, ref skip_existing, "Skip existing packages", null },
		{ "no-check-certificate", 0, 0, OptionArg.NONE, ref wget_no_check_certificate, "Pass --no-check-certificate to wget", null },
		{ "disable-devhelp", 0, 0, OptionArg.NONE, ref disable_devhelp, "Do not generate devhelp-packages", null },
		{ "", 0, 0, OptionArg.FILENAME_ARRAY, ref requested_packages, null, "FILE..." },
		{ null }
	};

	private void parse_metadata_package (Section section, Vala.MarkupReader reader, ref Vala.MarkupTokenType current_token, ref Vala.SourceLocation begin, ref Vala.SourceLocation end) {
		string start_tag = reader.name;
		Package pkg = null;

		string? ignore = reader.get_attribute ("ignore");
		if (ignore == null || ignore != "true") {
			string? maintainers = reader.get_attribute ("maintainers");
			string? name = reader.get_attribute ("name");
			string? c_docs = reader.get_attribute ("c-docs");
			string? vapi_image_source = reader.get_attribute ("vapi-image-source");
			string? home = reader.get_attribute ("home");
			string? deprecated_str = reader.get_attribute ("deprecated");
			bool is_deprecated = false;
			if (deprecated_str != null && deprecated_str == "true") {
				is_deprecated = true;
			}


			if (name == null) {
				xml_error (reader, current_token, begin, end, "error: %s: Missing attribute: name=\"\"".printf (start_tag));
				return ;
			}

			if (start_tag == "external-package") {
				bool is_local = "true".ascii_casecmp (reader.get_attribute ("local") ?? "false") == 0;
				string? external_link = reader.get_attribute ("link");
				string? devhelp_link = reader.get_attribute ("devhelp");
				if (external_link == null) {
					reporter.simple_error (null, "error: %s: Missing attribute: link=\"\" in %s", start_tag, name);
					return ;
				} else {
					pkg = new ExternalPackage (name, external_link, maintainers, devhelp_link, home, c_docs, is_deprecated, is_local);
					register_package (section, pkg);
				}
			} else {
				string? gallery = reader.get_attribute ("gallery");
				string? girs = reader.get_attribute ("gir");
				string? flags = reader.get_attribute ("flags");
				pkg = new Package (name, girs, maintainers, home, c_docs, vapi_image_source, gallery, flags, is_deprecated);
				register_package (section, pkg);
			}
		}

		current_token = reader.read_token (out begin, out end);

		if (current_token == Vala.MarkupTokenType.TEXT) {
			if (pkg != null) {
				pkg.description = Regex.split_simple ("[ |\t]*\n[ |\t]*\n[ |\t]*", reader.content.strip ());
				try {
					Regex regex = new Regex ("[\n|\t| ]+");
					for (int i = 0; i < pkg.description.length; i++) {
						string tmp = regex.replace (pkg.description[i], -1, 0, " ");
						pkg.description[i] = tmp.strip ();
					}
				} catch (Error e) {
					error (e.message);
				}
			}
			current_token = reader.read_token (out begin, out end);
		}

		if (current_token != Vala.MarkupTokenType.END_ELEMENT || reader.name != start_tag) {
			xml_error (reader, current_token, begin, end, "Expected: </%s> (got: %s '%s')".printf (start_tag, current_token.to_string (), reader.name));
			return ;
		}

		current_token = reader.read_token (out begin, out end);
	}

	private void parse_metadata_section (Section parent_section, Vala.MarkupReader reader, ref Vala.MarkupTokenType current_token, ref Vala.SourceLocation begin, ref Vala.SourceLocation end) {
		string name = reader.get_attribute ("name");
		if (name == null) {
			xml_error (reader, current_token, begin, end, "Expected: <section name=\"...\"");
			return ;
		}

		Section section = new Section (name);
		parent_section.sections.add (section);

		current_token = reader.read_token (out begin, out end);

		while (current_token != Vala.MarkupTokenType.END_ELEMENT && current_token != Vala.MarkupTokenType.EOF) {
			if (current_token != Vala.MarkupTokenType.START_ELEMENT || !(reader.name == "package" || reader.name == "external-package" || reader.name == "section")) {
				xml_error (reader, current_token, begin, end, "Expected: <section>|<package>|<external-package> (got: %s '%s')".printf (current_token.to_string (), reader.name));
				return ;
			}

			if (reader.name == "package" || reader.name == "external-package") {
				parse_metadata_package (section, reader, ref current_token, ref begin, ref end);
			} else if (reader.name == "section") {
				parse_metadata_section (section, reader, ref current_token, ref begin, ref end);
			} else {
				assert_not_reached ();
			}
		}

		if (current_token != Vala.MarkupTokenType.END_ELEMENT || reader.name != "section") {
			xml_error (reader, current_token, begin, end, "error: Expected: </section> (got: %s '%s')".printf (current_token.to_string (), reader.name));
			return ;
		}

		current_token = reader.read_token (out begin, out end);
	}

	private void load_metadata (string filename) {
		var reader = new Vala.MarkupReader (filename);

		Vala.SourceLocation begin;
		Vala.SourceLocation end;

		var current_token = reader.read_token (out begin, out end);
		current_token = reader.read_token (out begin, out end);
		current_token = reader.read_token (out begin, out end);

		if (current_token != Vala.MarkupTokenType.START_ELEMENT || reader.name != "packages") {
			reporter.simple_error (null, "error: Expected: <packages>");
			return ;
		}

		current_token = reader.read_token (out begin, out end);

		Section section = new Section ("");

		while (current_token != Vala.MarkupTokenType.END_ELEMENT && current_token != Vala.MarkupTokenType.EOF) {
			if (current_token != Vala.MarkupTokenType.START_ELEMENT || reader.name != "section") {
				reporter.simple_error (null, "Expected: <section> (got: %s '%s')", current_token.to_string (), reader.name);
				return ;
			}

			parse_metadata_section (section, reader, ref current_token, ref begin, ref end);
		}

		this.sections = section.sections;

		if (current_token != Vala.MarkupTokenType.END_ELEMENT || reader.name != "packages") {
			reporter.simple_error (null, "Expected: </packages> (got: %s '%s')", current_token.to_string (), reader.name);
			return ;
		}
	}

	private abstract class Node {
		public abstract void render (Renderer renderer);
	}

	private class Section : Node {
		public string name;
		public Gee.Collection<Package> packages = new Gee.ArrayList<Package> ();
		public Gee.Collection<Section> sections = new Gee.ArrayList<Section> ();

		public Section (string name) {
			this.name = name;
		}

		public Gee.Collection<Package> sorted_package_list () {
			Gee.ArrayList<Package> packages = new Gee.ArrayList<Package> ();
			packages.add_all (this.packages);
			packages.sort ((a, b) => {
				return ((Package) a).name.ascii_casecmp (((Package) b).name);
			});

			return packages;
		}

		public override void render (Renderer renderer) {
			renderer.render_section (this);
		}
	}

	private class Package : Node {
		public string? devhelp_link;
		public string? maintainers;
		public string online_link;
		public string[]? gir_names;
		public string name;
		public string? home;
		public string? c_docs;
		public string? vapi_image_source;
		public string flags;
		public bool is_deprecated;
		public string? gallery;
		public string[] description;
		public bool is_docbook = false;
		public string? sgml_path;
		public bool is_local;

		protected Package.dummy () {
		}

		public Package (string name, string? girs = null, string? maintainers = null, string? home = null, string? c_docs = null, string? vapi_image_source = null, string? gallery = null, string? flags = null, bool is_deprecated = false) {
			devhelp_link = "/" + name + "/" + name + ".tar.bz2";
			online_link = "/" + name + "/index.htm";
			this.is_deprecated = is_deprecated;
			this.maintainers = maintainers;
			this.gir_names = girs != null ? girs.split (",") : null;
			this.c_docs = c_docs;
			this.vapi_image_source = vapi_image_source;
			this.name = name;
			this.home = home;
			this.flags = flags ?? "";
			this.gallery = gallery;
			this.is_local = true;
		}

		public void load_metadata (string? gir_name, ErrorReporter reporter) {
			if (gir_name == null) {
				return ;
			}


			string meta_path = "documentation/%s/%s.valadoc.metadata".printf (name, gir_name);
			if (FileUtils.test (meta_path, FileTest.EXISTS)) {
				stdout.printf ("  load keyfile ...\n");

				try {
					var key_file = new KeyFile ();
					key_file.load_from_file (meta_path, KeyFileFlags.NONE);

					if (key_file.has_key ("General", "is_docbook")) {
						this.is_docbook = key_file.get_boolean ("General", "is_docbook");
					}
					if (key_file.has_key ("General", "index_sgml_online")) {
						this.sgml_path = key_file.get_string ("General", "index_sgml_online");
						if (this.sgml_path != null) {
							this.sgml_path = Path.build_path ("/", this.sgml_path, "index.sgml");
						}
					}
				} catch (Error e) {
					reporter.simple_error (null, "error: invalid key file: %s", e.message);
					return ;
				}
			}
		}

		public string? get_gir_file_metadata_path (string gir_name) {
			string path = Path.build_path (Path.DIR_SEPARATOR_S, "documentation", name, gir_name + ".valadoc.metadata");
			if (FileUtils.test (path, FileTest.IS_REGULAR)) {
				return Path.get_dirname (path);
			}

			return null;
		}

		public virtual string? get_gir_file (string? gir_name, ErrorReporter reporter) {
			if (gir_name == null) {
				return null;
			}

			string path = Path.build_path (Path.DIR_SEPARATOR_S, "girs", "gir-1.0", gir_name + ".gir");
			if (FileUtils.test (path, FileTest.IS_REGULAR)) {
				return path;
			}

			reporter.simple_warning (null, "Unable to find gir file `%s', some documentation might be missing", path);
			return null;
		}

		//public virtual string? get_catalog_file () {
		//	string path = Path.build_path (Path.DIR_SEPARATOR_S, "documentation", name, name + ".catalog");
		//	if (FileUtils.test (path, FileTest.IS_REGULAR)) {
		//		return path;
		//	}
		//
		//	return null;
		//}

		public virtual string? get_valadoc_file () {
			string path = Path.build_path (Path.DIR_SEPARATOR_S, "documentation", name, name + ".valadoc");
			if (FileUtils.test (path, FileTest.IS_REGULAR)) {
				return path;
			}

			return null;
		}

		public virtual string? get_vapi_path (string[] vapidirs) {
			foreach (string dir in vapidirs) {
				string path = Path.build_path (Path.DIR_SEPARATOR_S, dir, name + ".vapi");
				if (FileUtils.test (path, FileTest.EXISTS)) {
					return path;
				}
			}

			return null;
		}

		public override void render (Renderer renderer) {
			renderer.render_package (this);
		}
	}

	private class ExternalPackage : Package {

		public ExternalPackage (string name, string online_link, string? maintainers, string? devhelp_link, string? home, string? c_docs, bool is_deprecated, bool is_local) {
			base.dummy ();

			this.is_deprecated = is_deprecated;
			this.devhelp_link = devhelp_link;
			this.online_link = online_link;
			this.maintainers = maintainers;
			this.is_local = is_local;
			this.c_docs = c_docs;
			this.home = home;
			this.name = name;
		}

		public override string? get_gir_file (string? gir_name, ErrorReporter reporter) {
			return null;
		}

		public override string? get_valadoc_file () {
			return null;
		}

		public override string? get_vapi_path (string[] vapidirs) {
			return null;
		}

		//public override string? get_catalog_file () {
		//	return null;
		//}

		public override void render (Renderer renderer) {
			renderer.render_external_package (this);
		}
	}

	private abstract class Renderer {
		public abstract void render (string path, Gee.Collection<Node> sections);
		public abstract void render_section (Section section);
		public abstract void render_package (Package pkg);
		public abstract void render_external_package (ExternalPackage pkg);
	}

	public void load (string path) throws Error {
		Dir dirptr = Dir.open (path);
		string? dir;

		while ((dir = dirptr.read_name ()) != null) {
			string dir_path = Path.build_path (Path.DIR_SEPARATOR_S, path, dir);
			if (dir == ".sphinx" || dir == "scripts" || dir == "styles" || dir == "images" || dir == "templates") {
				continue;
			}

			if (FileUtils.test (dir_path, FileTest.IS_DIR)) {
				if (!packages_per_name.has_key (dir)) {
					register_package (null, new Package (dir));
				}
			}
		}
	}

	private Gee.ArrayList<Package> get_sorted_package_list () {
		Gee.ArrayList<Package> packages = new Gee.ArrayList<Package> ();
		packages.add_all (packages_per_name.values);
		packages.sort ((a, b) => {
			return ((Package) a).name.ascii_casecmp (((Package) b).name);
		});

		return packages;
	}

	private void generate_navigation (string path) {
		GLib.FileStream file = GLib.FileStream.open (path, "w");
		var writer = new Html.MarkupWriter (file, false);

		writer.start_tag ("div", {"class", "site_navigation"});
		writer.start_tag ("ul");

		Gee.ArrayList<Package> packages = get_sorted_package_list ();
		foreach (Package pkg in packages) {
			if (!pkg.is_local || regenerate_all_packages || pkg.name in requested_packages) {
				if (pkg.is_local) {
					writer.start_tag ("li").start_tag ("a", {"class", "package", "href", pkg.online_link}).text (pkg.name).end_tag ("a").end_tag ("li");
				} else {
					writer.start_tag ("li").start_tag ("a", {"class", "package external-link", "href", pkg.online_link}).text (pkg.name).end_tag ("a").end_tag ("li");
				}
			}
		}


		writer.end_tag ("ul");
		writer.end_tag ("div");
	}

	private class IndexRenderer : Renderer {
		private const int HEADER_LEVEL_START = 2;

		private Html.MarkupWriter writer;
		private int header_level = HEADER_LEVEL_START;

		public override void render (string path, Gee.Collection<Node> sections) {
			GLib.FileStream file = GLib.FileStream.open (path, "w");
			writer = new Html.MarkupWriter (file, false);

			// Intro:
			writer.start_tag ("h1").text ("Guides & References").end_tag ("h1");

			writer.start_tag ("p");
			writer.start_tag ("a", {"class", "document", "href", "https://wiki.gnome.org/Projects/Vala", "target", "_blank"}).text ("About Vala").end_tag ("a");
			writer.end_tag ("p");

			writer.start_tag ("p");
			writer.start_tag ("a", {"class", "document", "href", "https://wiki.gnome.org/Projects/Vala/Tutorial", "target", "_blank"}).text ("The Vala Tutorial by GNOME").end_tag ("a");
			writer.end_tag ("p");

			writer.start_tag ("p");
			writer.start_tag ("a", {"class", "document", "href", "https://wiki.gnome.org/Projects/Vala/ValaForCSharpProgrammers", "target", "_blank"}).text ("Vala for C# Programmers by GNOME").end_tag ("a");
			writer.end_tag ("p");

			writer.start_tag ("p");
			writer.start_tag ("a", {"class", "document", "href", "https://wiki.gnome.org/Projects/Vala/ValaForJavaProgrammers", "target", "_blank"}).text ("Vala for Java Programmers by GNOME").end_tag ("a");
			writer.end_tag ("p");

			writer.start_tag ("p");
			writer.start_tag ("a", {"class", "video", "href", "https://vimeo.com/9617309", "target", "_blank"}).text ("Gtk+ Kick-Start Tutorial for Vala by Alberto Ruiz").end_tag ("a");
			writer.end_tag ("p");

			writer.start_tag ("p");
			writer.start_tag ("a", {"class", "video", "href", "https://www.youtube.com/watch?v=Eqa38B0GV6U", "target", "_blank"}).text ("Vala Language Introduction by Andre Masella").end_tag ("a");
			writer.end_tag ("p");

			writer.start_tag ("p");
			writer.start_tag ("a", {"class", "video", "href", "https://www.youtube.com/watch?v=vxvZGf69nko", "target", "_blank"}).text ("Creating elementary OS apps with GTK & Vala").end_tag ("a");
			writer.end_tag ("p");

			writer.start_tag ("p");
			writer.start_tag ("a", {"class", "video", "href", "https://www.youtube.com/playlist?list=PLriKzYyLb28mn2lS3c5yqMHgLREi7kR9-", "target", "_blank"}).text ("Learn Vala and Gtk+ from Scratch (Playlist)").end_tag ("a");
			writer.end_tag ("p");

			writer.simple_tag ("hr");
			writer.start_tag ("h1").text ("Packages").end_tag ("h1");

			writer.start_tag ("h2").text ("Submitting API-Bugs and Patches").end_tag ("h2");
			writer.start_tag ("p");
			writer.text ("For all bindings where the status is not marked as external, and unless otherwise noted, bugs and pull-requests should be submitted to the Vala product in the ");
			writer.start_tag ("a", {"href", "https://gitlab.gnome.org/GNOME/vala", "target", "_blank"}).text ("GNOME GitLab instance").end_tag ("a");
			writer.text (".").end_tag ("p");

			writer.start_tag ("h2").text ("Projects without VAPI files").end_tag ("h2");
			writer.start_tag ("p").text ("Most GObject-instrospected projects are shipping their own bindings and Vala also ships with many of them. For many non-GObject introspected libraries, a repository is available in the ");
			writer.start_tag ("a", {"href", "https://gitlab.gnome.org/GNOME/vala-extra-vapis", "target", "_blank"}).text ("vala-extra-vapis").end_tag ("a");
			writer.text (" project in the GNOME GitLab instance.").end_tag ("p");

			foreach (Node node in sections) {
				node.render (this);
			}

			writer = null;
		}

		public override void render_section (Section section) {
			if (header_level == HEADER_LEVEL_START) {
				writer.simple_tag ("hr");
			}

			string tag = "h%d".printf (header_level);
			writer.start_tag (tag).text (section.name).end_tag (tag);

			header_level++;

			foreach (Node node in section.sections) {
				node.render (this);
			}

			foreach (Package pkg in section.sorted_package_list ()) {
				pkg.render (this);
			}

			header_level--;
		}

		public override void render_package (Package pkg) {
			if (regenerate_all_packages || pkg.name in requested_packages) {
				render_table_entry (pkg);
			}
		}

		public override void render_external_package (ExternalPackage pkg) {
			if (!pkg.is_local || regenerate_all_packages || pkg.name in requested_packages) {
				render_table_entry (pkg);
			}
		}

		private void render_table_entry (Package pkg) {

			writer.start_tag ("div", {"class", "highlight"});

			if (pkg.is_deprecated) {
				writer.start_tag ("a", {"class", "deprecated package", "href", pkg.online_link}).text (pkg.name).end_tag ("a");
			} else {
				writer.start_tag ("a", {"class", "package", "href", pkg.online_link}).text (pkg.name).end_tag ("a");
			}

			if (pkg is ExternalPackage) {
				writer.simple_tag ("img", {"src", "/images/external_link.svg", "alt", "This valadoc is on another site"});
			}

			writer.start_tag ("div", {"class", "links"});

			writer.start_tag ("p", {"class", "homepage"});
			if (pkg.home != null) {
				writer.start_tag ("a", {"href", pkg.home, "target", "_blank"}).text ("Home").end_tag ("a");
			}
			writer.end_tag ("p");

			writer.start_tag ("p", {"class", "cdocs"});
			if (pkg.c_docs != null) {
				writer.start_tag ("a", {"href", pkg.c_docs, "target", "_blank"}).text ("C Docs").end_tag ("a");
			}
			writer.end_tag ("p");

			if (pkg.devhelp_link != null && disable_devhelp == false) {
				writer.start_tag ("p", {"class", "devhelp"});
				writer.start_tag ("a", {"href", pkg.devhelp_link}).text ("Devhelp Package").end_tag ("a");
				writer.end_tag ("p");
			}

			writer.end_tag ("div");

			if (pkg.description != null) {
				writer.start_tag ("div", {"class", "description"});
				foreach (string line in pkg.description) {
					line._strip ();
					writer.start_tag ("p").text (line).end_tag ("p");
				}
				writer.end_tag ("div");
			}

			writer.end_tag ("div");
		}
	}

	private void generate_wiki_index (Package pkg, string path, bool has_examples, bool is_devhelp) {
		FileStream stream = FileStream.open (path, "w");
		assert (stream != null);

		if (pkg.description != null) {
			foreach (string line in pkg.description) {
				stream.puts (line);
				stream.putc ('\n');
			}
		}
		if (pkg.is_deprecated) {
			stream.puts ("\n''//Warning:// This package is deprecated!''\n");
		}

		if (pkg.is_deprecated || pkg.description != null) {
			stream.putc ('\n');
		}

		if (pkg.home != null) {
			stream.printf (" * ''Home:'' [[%s]]\n", pkg.home);
		}
		if (pkg.c_docs != null) {
			stream.printf (" * ''C-Documentation:'' [[%s]]\n", pkg.c_docs);
		}
		if (pkg.maintainers != null) {
			stream.printf (" * ''Binding-Maintainer(s): %s''\n", pkg.maintainers);
		}
		if (is_devhelp == false && disable_devhelp == false) {
			if (pkg.devhelp_link != null) {
				stream.printf (" * ''[[%s|Devhelp-Package download]]''\n", pkg.devhelp_link);
			}
		}
		if (pkg.gallery != null) {
			stream.puts (" * ''[[widget-gallery.valadoc|Widget Gallery]]''\n");
		}
		if (has_examples) {
			stream.puts (" * ''[[example-listing-index.valadoc|Example listing]]''\n");
		}
	}

	private void generate_index (string path) {
		IndexRenderer renderer = new IndexRenderer ();
		renderer.render (path, sections);

		try {
			copy_data ();
		} catch (Error e) {
			reporter.simple_error (null, "error: Can't copy data: %s", e.message);
		}
	}

	public void generate (string path) {
		stdout.printf ("generate index ...\n");

		generate_navigation (path + ".navi.tpl");
		generate_index (path + ".content.tpl");
	}

	public void regenerate_all_known_packages () throws Error {
		foreach (var pkg in packages_per_name.values) {
			if (pkg is ExternalPackage == false) {
				try {
					build_doc_for_package (pkg);
				} catch (Error e) {
					stderr.printf ("%s\n", e.message);
					has_error = true;
				}
			}
		}

		print_stored_messages ();
	}

	public void generate_configs (string path) throws Error {
		string constants_path = Path.build_filename (path, "constants.php");
		string path_prefix = Path.build_filename (path, "prefix.conf");

		var _prefix = FileStream.open (path_prefix, "w");
		_prefix.printf ("%s", prefix);

		var php = FileStream.open (constants_path, "w");

    php.printf ("<?php\n");
    php.printf ("\t// Vala generated file. I'm sorry. Look at generator.vala line 752-ish\n\n");
    php.printf ("\t$prefix = \"%s\";\n", prefix);
    php.printf ("\n");

    php.printf ("\t$mysqli = new mysqli('p:127.0.0.1', '', '', '', 51413);\n");
    php.printf ("\t$res = mysqli_query($mysqli, \"SHOW TABLES\");\n");
    php.printf ("\t$pkgs = array();\n");
    php.printf ("\twhile ($row = $res->fetch_assoc()) {\n");
    php.printf ("\t\t$pkgs[] = $row['Index'];\n");
    php.printf ("\t}\n");
    php.printf ("\t$res->close ();\n");
    php.printf ("\t$allpkgs = implode(', ', $pkgs);\n\n");

    php.printf ("?>\n");
	}

	public void regenerate_packages (string[] packages) throws Error {
		Gee.LinkedList<Package> queue = new Gee.LinkedList<Package> ();

		foreach (string pkg_name in packages) {
			Package? pkg = packages_per_name.get (pkg_name);
			if (pkg == null) {
				reporter.simple_error (null, "error: Unknown package %s", pkg_name);
			}

			queue.add (pkg);
		}

		if (reporter.errors > 0) {
			return ;
		}

		foreach (Package pkg in queue) {
			try {
				build_doc_for_package (pkg);
			} catch (Error e) {
				stderr.printf ("%s\n", e.message);
				has_error = true;
			}
		}

		print_stored_messages ();
	}

	private void build_doc_for_package (Package pkg) throws Error {
		if (skip_existing && FileUtils.test (Path.build_filename (output_directory, pkg.name), FileTest.IS_DIR)) {
			stdout.printf ("skip \'%s\' ...\n", pkg.name);
			return ;
		}

		if (pkg.get_vapi_path (vapidirs) == null) {
			this.unavailable_packages.add (pkg);
			return ;
		}

		stdout.printf ("create \'%s\' ...\n", pkg.name);


		DirUtils.create ("documentation/%s/".printf (pkg.name), 0755);
		DirUtils.create ("documentation/%s/wiki".printf (pkg.name), 0755);


		foreach (unowned string gir_name in pkg.gir_names) {
			pkg.load_metadata (gir_name, reporter);
		}

		if (pkg.sgml_path != null) {
			stdout.printf ("  get index.sgml ...\n");

			if (!FileUtils.test ("documentation/%s/index.sgml".printf (pkg.name), FileTest.EXISTS)) {
				try {
					Process.spawn_command_line_sync ("wget %s -O documentation/%s/index.sgml \"%s\"".printf (global_wget_flags, pkg.name, pkg.sgml_path));
				} catch (SpawnError e) {
					error (e.message);
				}
			}
		}


		StringBuilder builder = new StringBuilder ();
		builder.append_printf ("valadoc-%s --target-glib %s --importdir girs --doclet \"%s\" -o \"tmp/%s\" \"%s\" --vapidir \"%s\" --girdir \"%s\" %s --use-svg-images",
			Vala.API_VERSION, target_glib, docletpath, pkg.name, pkg.get_vapi_path (vapidirs), Path.get_dirname (pkg.get_vapi_path (vapidirs)), girdir, pkg.flags);

		if (disable_devhelp == true) {
			builder.append (" -X --disable-devhelp");
		}

		string external_docu_path = pkg.get_valadoc_file ();
		if (external_docu_path != null) {
			stdout.printf ("  select .valadoc:        %s\n".printf (external_docu_path));

			builder.append_printf (" --importdir documentation/%s", pkg.name);
			builder.append_printf (" --import %s", pkg.name);
		}

		if (pkg.gir_names != null) {
			foreach (unowned string gir_name in pkg.gir_names) {
				var gir_path = pkg.get_gir_file (gir_name, reporter);
				if (gir_path == null) {
					continue;
				}

				stdout.printf ("  select .gir:            %s\n", gir_path);

				builder.append_printf (" --importdir \"%s\"", girdir);
				builder.append_printf (" --import %s", gir_name);

				load_images_gir (pkg, gir_name);

				string metadata_path = pkg.get_gir_file_metadata_path (gir_name);
				if (metadata_path != null) {
					builder.append_printf (" --metadatadir %s", metadata_path);
				}
			}
		} else if (pkg.vapi_image_source != null) {
			load_images_vapi (pkg);
			builder.append_printf (" --alternative-resource-dir documentation/%s/vapi-images/", pkg.name);
		}

		if (pkg.gallery != null) {
			generate_widget_gallery (pkg);

			builder.append (" --importdir \"tmp\"");
			builder.append_printf (" --import \"%s-widget-gallery\"", pkg.name);
		}

		stdout.printf ("===== %s =====\n", pkg.name);

		bool has_examples = false;
		string example_path = "examples/%s/%s.valadoc.examples".printf (pkg.name, pkg.name);
		if (FileUtils.test (example_path, FileTest.IS_REGULAR)) {
			string output = "examples/%s-examples.valadoc".printf (pkg.name);
			stdout.printf ("  select example.valadoc: %s\n", output);
			FileUtils.remove (output);

			try {
				int exit_status = 0;
				string? standard_output = null;
				string? standard_error = null;

				Process.spawn_command_line_sync ("./valadoc-example-gen \"%s\" \"%s\" \"%s\"".printf (example_path, output, "documentation/%s/wiki".printf (pkg.name)), out standard_output, out standard_error, out exit_status);
				if (exit_status != 0) {
					stdout.printf ("%s\n", builder.str);
					if (standard_error != null) {
						stdout.printf (standard_error);
					}
					if (standard_output != null) {
						stdout.printf (standard_output);
					}
					throw new SpawnError.FAILED ("Exit status != 0");
				}
			} catch (SpawnError e) {
				stdout.printf ("ERROR: Can't generate documentation for %s.\n", pkg.name);
				throw e;
			}

			builder.append_printf (" --importdir examples --import %s-examples", pkg.name);
			has_examples = true;
		}


		string wiki_path = "documentation/%s/wiki/index.valadoc".printf (pkg.name);
		bool delete_wiki_path = false;
		if (FileUtils.test (wiki_path, FileTest.IS_REGULAR)) {
			stdout.printf ("  select .valadoc (wiki): documentation/%s/wiki/*.valadoc\n", pkg.name);
		} else {
			string devhelp_wiki_path = "documentation/%s/wiki/devhelp-index.valadoc".printf (pkg.name);
			generate_wiki_index (pkg, devhelp_wiki_path, has_examples, true);
			generate_wiki_index (pkg, wiki_path, has_examples, false);
			delete_wiki_path = true;
		}
		builder.append_printf (" --wiki documentation/%s/wiki", pkg.name);


		try {
			int exit_status = 0;
			string? standard_output = null;
			string? standard_error = null;

			stdout.puts ("  run valadoc ...\n");
			Process.spawn_command_line_sync (builder.str, out standard_output, out standard_error, out exit_status);

			stdout.printf ("%s\n", builder.str);
			if (standard_error != null) {
				stdout.printf (standard_error);
			}
			if (standard_output != null) {
				stdout.printf (standard_output);
			}
			standard_output = null;
			standard_error = null;

			if (exit_status != 0) {
				throw new SpawnError.FAILED ("valadoc exit status %d != 0", exit_status);
			}

			Process.spawn_command_line_sync ("rm -r -f %s".printf (Path.build_path (Path.DIR_SEPARATOR_S, output_directory, pkg.name)));
			Process.spawn_command_line_sync ("mv tmp/%s/%s \"%s\"".printf (pkg.name, pkg.name, output_directory));
		} catch (SpawnError e) {
			stdout.printf ("ERROR: Can't generate documentation for %s.\n", pkg.name);
			throw e;
		} finally {
			if (delete_wiki_path) {
				FileUtils.unlink (wiki_path);
			}
		}
	}

	private void collect_images (string content, Gee.HashSet<string> images, bool is_docbook) {
		if (is_docbook) {
			// Docbook:
			Gtkdoc.Scanner scanner = new Gtkdoc.Scanner ();
			scanner.reset (content);

			for (Gtkdoc.Token token = scanner.next (); token.type != Gtkdoc.TokenType.EOF; token = scanner.next ()) {
				if (token.type == Gtkdoc.TokenType.XML_OPEN && (token.content == "inlinegraphic" || token.content == "graphic")) {
					if (token.attributes == null) {
						continue ;
					}

					string? link = token.attributes.get ("fileref");
					if (link != null) {
						images.add (link);
					}
				}
			}
		} else {
			// Markdown:
			try {
				MatchInfo info;
				markdown_img_regex.match (content, 0, out info);
				int path_num = markdown_img_regex.get_string_number ("img");
				while (info.matches ()) {
					string link = info.fetch (path_num);
					images.add (link);
					info.next ();
				}
			} catch (GLib.RegexError e) {
				error (e.message);
			}
		}
	}

	private void generate_widget_gallery (Package pkg) throws Error {
		if (pkg.gallery == null) {
			return ;
		}

		int pos = pkg.gallery.last_index_of_char ('/');
		if (pos < 0) {
			reporter.simple_error (null, "Invalid widget gallery path\n");
			throw new FileError.FAILED ("Invalid widget gallery path");
		}
		string search_path = pkg.gallery.substring (0, pos);


		stdout.printf ("  widget gallery\n");

		if (!FileUtils.test ("tmp/c-gallery.html", FileTest.EXISTS)) {
			try {
				Process.spawn_command_line_sync ("wget %s -O tmp/c-gallery.html \"%s\"".printf (global_wget_flags, pkg.gallery));
			} catch (SpawnError e) {
				error (e.message);
			}
		}

		Gee.HashMap<string, string> images = new Gee.HashMap<string, string> ();

		var markup_reader = new Vala.MarkupReader ("tmp/c-gallery.html");
		Vala.MarkupTokenType token = Vala.MarkupTokenType.START_ELEMENT;
		Vala.SourceLocation token_begin;
		Vala.SourceLocation token_end;

		token = markup_reader.read_token (out token_begin, out token_end);
		while (token != Vala.MarkupTokenType.EOF) {
			if (token == Vala.MarkupTokenType.START_ELEMENT && markup_reader.name == "div" && markup_reader.get_attribute ("class") == "gallery-float") {
				string? widget = null;
				string? img = null;

				token = markup_reader.read_token (out token_begin, out token_end);
				if (token == Vala.MarkupTokenType.START_ELEMENT && markup_reader.name == "a") {
					widget = markup_reader.get_attribute ("title");

					token = markup_reader.read_token (out token_begin, out token_end);
					if (token == Vala.MarkupTokenType.START_ELEMENT && markup_reader.name == "img") {
						img = markup_reader.get_attribute ("src");
						images.set (widget, img);
					} else {
						continue;
					}
				} else {
					continue;
				}
			}
			token = markup_reader.read_token (out token_begin, out token_end);
		}

		FileUtils.unlink ("tmp/c-gallery.html");



		DirUtils.create ("documentation/%s/gallery-images/".printf (pkg.name), 0755);

		// Download:
		if (download_images) {
			images.foreach ((entry) => {
			if (!FileUtils.test ("documentation/%s/gallery-images/%s".printf (pkg.name, entry.value), FileTest.EXISTS)) {
					try {
						string link = Path.build_path (Path.DIR_SEPARATOR_S, search_path, entry.value);
						Process.spawn_command_line_sync ("wget %s --directory-prefix documentation/%s/gallery-images/ \"%s\"".printf (global_wget_flags, pkg.name, link));
					} catch (SpawnError e) {
						error (e.message);
					}
				}
				return true;
			});
		}

		FileStream stream = FileStream.open ("documentation/%s/wiki/widget-gallery.valadoc".printf (pkg.name), "w");
		assert (stream != null);

		stream.puts ("== Widget Gallery ==\n");
		stream.putc ('\n');

		images.foreach ((entry) => {
			stream.printf ("{@link c::%s}:\n", entry.key);
			stream.putc ('\n');
			stream.printf ("{{../gallery-images/%s|%s}}\n", entry.value, entry.key);
			stream.putc ('\n');
			return true;
		});


		stream = FileStream.open ("tmp/%s-widget-gallery.valadoc".printf (pkg.name), "w");
		assert (stream != null);

		bool first_entry = true;

		images.foreach ((entry) => {
			if (first_entry == false) {
				stream.puts ("\n\n");
			}

			stream.puts ("/**\n");
			stream.printf (" * {{../documentation/%s/gallery-images/%s|%s}}\n", pkg.name, entry.value, entry.key);
			stream.puts (" */\n");
			stream.printf ("c::%s::append", entry.key);

			first_entry = false;
			return true;
		});
	}


	private Regex cmnt_regex;
	private Regex content_regex;

	private bool load_images_vapi (Package pkg) {
		if (pkg.vapi_image_source == null) {
			return false;
		}

		if (!download_images) {
			return false;
		}

		string? vapi_path = pkg.get_vapi_path (vapidirs);
		if (vapi_path == null) {
			return false;
		}

		// {{[path]}}
		// {{[path]|[description]}}

		stdout.printf ("  download images (vapi) ...\n");

		bool has_images = false;
		try {
			string file_content;
			FileUtils.get_contents (vapi_path, out file_content);

			if (cmnt_regex == null) {
				cmnt_regex = new Regex ("/\\*\\*(.*?)\\*/", RegexCompileFlags.OPTIMIZE | RegexCompileFlags.DOTALL);
			}
			MatchInfo cmnt_info;
			int cmnt_start;
			int cmnt_end;

			if (content_regex == null) {
				content_regex = new Regex ("{{{(.*?)}}}|{{(.*?)(\\|.*?)?}}", RegexCompileFlags.OPTIMIZE);
			}
			MatchInfo content_info;

			cmnt_regex.match (file_content, 0, out cmnt_info);
			while (cmnt_info.matches ()) {
				cmnt_info.fetch_pos (1, out cmnt_start, out cmnt_end);
				cmnt_info.next ();

				// All links:
				content_regex.match_full (file_content, cmnt_end, cmnt_start, 0, out content_info);
				while (content_info.matches ()) {
					string source = content_info.fetch (1);
					string image_name = content_info.fetch (2);
					if (source != "") {
						// TODO: download external source code
					} else if (image_name != "") {
						image_name = Path.get_basename (image_name);

						if (!FileUtils.test ("documentation/%s/vapi-images/%s".printf (pkg.name, image_name), FileTest.EXISTS)) {
							string link = get_image_link (pkg.vapi_image_source, image_name);
							Process.spawn_command_line_sync ("wget %s --directory-prefix documentation/%s/vapi-images/ \"%s\"".printf (global_wget_flags, pkg.name, link));
							has_images = true;
						}
					}
					content_info.next ();
				}
			}

		} catch (Error e) {
			error (e.message);
		}

		return has_images;
	}

	private Regex regex_launchpad_link;

	private string get_image_link (string base_url, string image_name) {
		string url = Path.build_path ("/", base_url, image_name);
		if (url.has_prefix ("http://bazaar.launchpad.net/")) {
			try {
				uint8[] _content;
				File page_file = File.new_for_uri (url);
				page_file.load_contents (null, out _content, null);
				unowned string content = (string) _content;

				if (regex_launchpad_link == null) {
					regex_launchpad_link = new Regex ("<a href=\"(.*?)\">download file</a>", RegexCompileFlags.OPTIMIZE);
				}

				MatchInfo info;
				regex_launchpad_link.match (content, 0, out info);
				NetworkAddress address = NetworkAddress.parse_uri (base_url, 80) as NetworkAddress; // cast is required by vala <= 0.28
				assert (address != null);
				return address.get_scheme () + "://" + Path.build_path ("/", address.get_hostname (), info.fetch (1));
			} catch (Error e) {
				error (e.message);
			}
		}

		return url;
	}

	private void load_images_gir (Package pkg, string gir_name) {
		if (pkg.c_docs == null) {
			return ;
		}

		string? gir_path = pkg.get_gir_file (gir_name, reporter);
		if (gir_path == null) {
			return ;
		}

		if (!download_images) {
			return ;
		}

		stdout.printf ("  download images (gir) ...\n");

		var markup_reader = new Vala.MarkupReader (gir_path);
		var token = Vala.MarkupTokenType.EOF;
		Vala.SourceLocation token_begin;
		Vala.SourceLocation token_end;

		Gee.HashSet<string> images = new Gee.HashSet<string> ();

		do {
			token = markup_reader.read_token (out token_begin, out token_end);

			if (token == Vala.MarkupTokenType.START_ELEMENT && markup_reader.name == "doc") {
				token = markup_reader.read_token (out token_begin, out token_end);
				if (token == Vala.MarkupTokenType.TEXT) {
					this.collect_images (markup_reader.content, images, pkg.is_docbook);
				}
			}
		} while (token != Vala.MarkupTokenType.EOF);

		foreach (string image_name in images) {
			if (!FileUtils.test ("documentation/%s/gir-images/%s".printf (pkg.name, image_name), FileTest.EXISTS)) {
				try {
					string link = get_image_link (pkg.c_docs, image_name);
					Process.spawn_command_line_sync ("wget %s --directory-prefix documentation/%s/gir-images/ \"%s\"".printf (global_wget_flags, pkg.name, link));
				} catch (SpawnError e) {
					error (e.message);
				}
			}
		}


		if (images.size > 0) {
			string metadata_file_path = "documentation/%s/%s.valadoc.metadata".printf (pkg.name, gir_name);
			if (!FileUtils.test (metadata_file_path, FileTest.EXISTS)) {
				FileStream stream = FileStream.open (metadata_file_path, "w");
				stream.printf ("\n");
				stream.printf ("[General]\n");
				stream.printf ("resources = gir-images/\n");
				stream.printf ("\n");
			}
		}
	}

	private static void copy_dir (string path, string output) throws Error {
		Dir dir = Dir.open (path);
		for (string? file = dir.read_name (); file != null; file = dir.read_name ()) {
			string src_file_path = Path.build_filename (path, file);
			string dest_file_path = Path.build_filename (output, file);
			if (FileUtils.test (src_file_path, FileTest.IS_DIR)) {
				DirUtils.create_with_parents (dest_file_path, 0755); // mkdir if necessary
				copy_dir (src_file_path, dest_file_path); // copy directories recursively
			} else {
				Valadoc.copy_file (src_file_path, dest_file_path);
			}
		}
	}

	private void copy_data () throws Error {
		copy_dir ("data", output_directory);
	}

	public static int main (string[] args) {
		ErrorReporter reporter = new ErrorReporter ();

		try {
			var opt_context = new OptionContext ("- Vala Documentation Tool");
			opt_context.set_help_enabled (true);
			opt_context.add_main_entries (options, null);
			opt_context.parse (ref args);
		} catch (OptionError e) {
			stdout.printf ("error: %s\n", e.message);
			stdout.printf ("Run '%s --help' to see a full list of available command line options.\n", args[0]);
			return -1;
		}

		if (prefix == null) {
			stdout.printf ("error: prefix == null\n");
			return -1;
		}

		if (target_glib == null) {
			stdout.printf ("error: target_glib == null\n");
			return -1;
		}

		if (FileUtils.test ("tmp", FileTest.IS_DIR)) {
			stdout.printf ("error: tmp already exist.\n");
			return -1;
		}

		if (output_directory == null) {
			output_directory = "valadoc.org";
		}

		metadata_path = "documentation/packages.xml";

		if (docletpath == null) {
			docletpath = ".";
		}

		if (vapidirs == null) {
			stdout.printf ("error: --vapidir is missing\n");
			return -1;
		}

		if (!FileUtils.test (output_directory, FileTest.IS_DIR)) {
			if (DirUtils.create_with_parents (output_directory, 0777) != 0) {
				stdout.printf ("error: can't create output-directory: %s.\n", output_directory);
				return -1;
			}
		}

		if (DirUtils.create ("tmp", 0777) != 0) {
			stdout.printf ("error: can't create tmp/.\n");
			return -1;
		}


		int return_val = 0;

		try {
			IndexGenerator generator = new IndexGenerator (reporter);
			generator.load_metadata (metadata_path);
			if (reporter.errors > 0) {
				return -1;
			}

			generator.load (output_directory);
			if (reporter.errors > 0) {
				return -1;
			}

			if (regenerate_all_packages) {
				generator.regenerate_all_known_packages ();
			} else {
				generator.regenerate_packages (requested_packages);
			}

			if (reporter.errors > 0) {
				return -1;
			}

			string index = Path.build_path (Path.DIR_SEPARATOR_S, output_directory, "index.htm");
			generator.generate (index);

			generator.generate_configs (output_directory);

			if (reporter.errors > 0) {
				return -1;
			}

			if (generator.has_error) {
				return_val = -1;
			}

		} catch (Error e) {
			return_val = -1;
		}

		DirUtils.remove ("tmp");
		return return_val;
	}

	//private void xml_warning (MarkupReader reader, MarkupTokenType current_token, MarkupSourceLocation begin, MarkupSourceLocation end, string message) {
	//	reporter.warning (reader.filename, begin.line, begin.column, end.column,
	//					  reader.get_line_content (begin.line), message);
	//}

	private void xml_error (Vala.MarkupReader reader, Vala.MarkupTokenType current_token, Vala.SourceLocation begin, Vala.SourceLocation end, string message) {
		reporter.error (reader.filename, begin.line, begin.column, end.column,
						"", message);
	}
}
