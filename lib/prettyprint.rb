# frozen_string_literal: true
#
# This class implements a pretty printing algorithm. It finds line breaks and
# nice indentations for grouped structure.
#
# By default, the class assumes that primitive elements are strings and each
# byte in the strings have single column in width. But it can be used for
# other situations by giving suitable arguments for some methods:
# * newline object and space generation block for PrettyPrint.new
# * optional width argument for PrettyPrint#text
# * PrettyPrint#breakable
#
# There are several candidate uses:
# * text formatting using proportional fonts
# * multibyte characters which has columns different to number of bytes
# * non-string formatting
#
# == Bugs
# * Box based formatting?
#
# Report any bugs at http://bugs.ruby-lang.org
#
# == References
# Christian Lindig, Strictly Pretty, March 2000,
# http://www.st.cs.uni-sb.de/~lindig/papers/#pretty
#
# Philip Wadler, A prettier printer, March 1998,
# http://homepages.inf.ed.ac.uk/wadler/topics/language-design.html#prettier
#
# == Author
# Tanaka Akira <akr@fsij.org>
#
class PrettyPrint

  # This is a convenience method which is same as follows:
  #
  #   begin
  #     q = PrettyPrint.new(output, maxwidth, newline, &genspace)
  #     ...
  #     q.flush
  #     output
  #   end
  #
  def PrettyPrint.format(output=''.dup, maxwidth=80, newline="\n", genspace=lambda {|n| ' ' * n})
    q = PrettyPrint.new(output, maxwidth, newline, &genspace)
    yield q
    q.flush
    output
  end

  # This is similar to PrettyPrint::format but the result has no breaks.
  #
  # +maxwidth+, +newline+ and +genspace+ are ignored.
  #
  # The invocation of +breakable+ in the block doesn't break a line and is
  # treated as just an invocation of +text+.
  #
  def PrettyPrint.singleline_format(output=''.dup, maxwidth=nil, newline=nil, genspace=nil)
    q = SingleLine.new(output)
    yield q
    output
  end

  # Creates a buffer for pretty printing.
  #
  # +output+ is an output target. If it is not specified, '' is assumed. It
  # should have a << method which accepts the first argument +obj+ of
  # PrettyPrint#text, the first argument +sep+ of PrettyPrint#breakable, the
  # first argument +newline+ of PrettyPrint.new, and the result of a given
  # block for PrettyPrint.new.
  #
  # +maxwidth+ specifies maximum line length. If it is not specified, 80 is
  # assumed. However actual outputs may overflow +maxwidth+ if long
  # non-breakable texts are provided.
  #
  # +newline+ is used for line breaks. "\n" is used if it is not specified.
  #
  # The block is used to generate spaces. {|width| ' ' * width} is used if it
  # is not given.
  #
  def initialize(output=''.dup, maxwidth=80, newline="\n", &genspace)
    @output = output
    @maxwidth = maxwidth
    @newline = newline
    @genspace = genspace || lambda {|n| ' ' * n}
    @groups = [Group.new(0)]
    @target = @groups.last.contents
  end

  # The output object.
  #
  # This defaults to '', and should accept the << method
  attr_reader :output

  # The maximum width of a line, before it is separated in to a newline
  #
  # This defaults to 80, and should be an Integer
  attr_reader :maxwidth

  # The value that is appended to +output+ to add a new line.
  #
  # This defaults to "\n", and should be String
  attr_reader :newline

  # A lambda or Proc, that takes one argument, of an Integer, and returns
  # the corresponding number of spaces.
  #
  # By default this is:
  #   lambda {|n| ' ' * n}
  attr_reader :genspace

  # The stack of groups that are being printed.
  attr_reader :groups

  # The current array of contents that calls to methods that generate print tree
  # nodes will append to.
  attr_reader :target

  # Returns the group most recently added to the stack.
  #
  # Contrived example:
  #   out = ""
  #   => ""
  #   q = PrettyPrint.new(out)
  #   => #<PrettyPrint:0x82f85c0 @output="", @maxwidth=80, @newline="\n", @genspace=#<Proc:0x82f8368@/home/vbatts/.rvm/rubies/ruby-head/lib/ruby/2.0.0/prettyprint.rb:82 (lambda)>, @output_width=0, @buffer_width=0, @buffer=[], @group_stack=[#<PrettyPrint::Group:0x82f8138 @depth=0, @breakables=[], @break=false>], @group_queue=#<PrettyPrint::GroupQueue:0x82fb7c0 @queue=[[#<PrettyPrint::Group:0x82f8138 @depth=0, @breakables=[], @break=false>]]>, @indent=0>
  #   q.group {
  #     q.text q.current_group.inspect
  #     q.text q.newline
  #     q.group(q.current_group.depth + 1) {
  #       q.text q.current_group.inspect
  #       q.text q.newline
  #       q.group(q.current_group.depth + 1) {
  #         q.text q.current_group.inspect
  #         q.text q.newline
  #         q.group(q.current_group.depth + 1) {
  #           q.text q.current_group.inspect
  #           q.text q.newline
  #         }
  #       }
  #     }
  #   }
  #   => 284
  #    puts out
  #   #<PrettyPrint::Group:0x8354758 @depth=1, @breakables=[], @break=false>
  #   #<PrettyPrint::Group:0x8354550 @depth=2, @breakables=[], @break=false>
  #   #<PrettyPrint::Group:0x83541cc @depth=3, @breakables=[], @break=false>
  #   #<PrettyPrint::Group:0x8347e54 @depth=4, @breakables=[], @break=false>
  def current_group
    groups.last
  end

  # This adds +obj+ as a text of +width+ columns in width.
  #
  # If +width+ is not specified, obj.length is used.
  #
  def text(obj, width=obj.length)
    doc = target.last

    unless Text === doc
      doc = Text.new
      target << doc
    end

    doc.add(obj, width)
    doc
  end

  # This is similar to #breakable except
  # the decision to break or not is determined individually.
  #
  # Two #fill_breakable under a group may cause 4 results:
  # (break,break), (break,non-break), (non-break,break), (non-break,non-break).
  # This is different to #breakable because two #breakable under a group
  # may cause 2 results:
  # (break,break), (non-break,non-break).
  #
  # The text +sep+ is inserted if a line is not broken at this point.
  #
  # If +sep+ is not specified, " " is used.
  #
  # If +width+ is not specified, +sep.length+ is used. You will have to
  # specify this when +sep+ is a multibyte character, for example.
  #
  def fill_breakable(sep=' ', width=sep.length)
    group { breakable sep, width }
  end

  # This says "you can break a line here if necessary", and a +width+\-column
  # text +sep+ is inserted if a line is not broken at the point.
  #
  # If +sep+ is not specified, " " is used.
  #
  # If +width+ is not specified, +sep.length+ is used. You will have to
  # specify this when +sep+ is a multibyte character, for example.
  #
  # By default, if the surrounding group is broken and a newline is inserted,
  # the printer will indent the subsequent line up to the current level of
  # indentation. You can disable this behavior with the +indent+ argument if
  # that's not desired.
  #
  def breakable(sep=' ', width=sep.length, indent: true)
    doc = Breakable.new(sep, width, indent: indent)
    target << doc
    doc
  end

  # Groups line break hints added in the block. The line break hints are all
  # to be used or not.
  #
  # If +indent+ is specified, the method call is regarded as nested by
  # nest(indent) { ... }.
  #
  # If +open_obj+ is specified, <tt>text open_obj, open_width</tt> is called
  # before grouping. If +close_obj+ is specified, <tt>text close_obj,
  # close_width</tt> is called after grouping.
  #
  def group(indent=0, open_obj='', close_obj='', open_width=open_obj.length, close_width=close_obj.length)
    text open_obj, open_width

    doc = Group.new(groups.last.depth + 1)
    groups << doc
    target << doc

    with_target(doc.contents) do
      if indent != 0
        nest(indent) { yield }
      else
        yield
      end
    end

    groups.pop
    text close_obj, close_width

    doc
  end

  # Increases left margin after newline with +indent+ for line breaks added in
  # the block.
  #
  def nest(indent)
    doc = Align.new(indent: indent)
    target << doc

    with_target(doc.contents) { yield }
    doc
  end

  # There are two modes in printing, break and flat. When we're in break mode,
  # any lines will use their newline, any if-breaks will use their break
  # contents, etc.
  MODE_BREAK = 1

  # This is another print mode much like MODE_BREAK. When we're in flat mode, we
  # attempt to print everything on one line until we either hit a broken group,
  # a forced line, or the maximum width.
  MODE_FLAT = 2

  # Flushes all of the generated print tree onto the output buffer, then clears
  # the generated tree from memory.
  def flush
    # First, get the root group, since we placed one at the top to begin with.
    doc = groups.first

    # This represents how far along the current line we are. It gets reset
    # back to 0 when we encounter a newline.
    position = 0

    # This is our command stack. A command consists of a triplet of an
    # indentation level, the mode (break or flat), and a doc node.
    commands = [[IndentLevel.new(genspace: genspace), MODE_BREAK, doc]]

    # This is a small optimization boolean. It keeps track of whether or not
    # when we hit a group node we should check if it fits on the same line.
    should_remeasure = false

    # This is a linear stack instead of a mutually recursive call defined on
    # the individual doc nodes for efficiency.
    while (indent, mode, doc = commands.pop)
      case doc
      when Text
        doc.objs.each { |object| output << object }
        position += doc.width
      when Array
        doc.reverse_each { |part| commands << [indent, mode, part] }
      when Align
        commands << [indent.align(doc.indent), mode, doc.contents]
      when Group
        if mode == MODE_FLAT && !should_remeasure
          commands <<
            [indent, doc.break? ? MODE_BREAK : MODE_FLAT, doc.contents]
        else
          should_remeasure = false
          next_cmd = [indent, MODE_FLAT, doc.contents]

          if !doc.break? && fits?(next_cmd, commands, maxwidth - position)
            commands << next_cmd
          else
            commands << [indent, MODE_BREAK, doc.contents]
          end
        end
      when Breakable
        if mode == MODE_FLAT
          output << doc.separator
          position += doc.width
          next
        end

        if !doc.indent?
          output << newline

          if indent.root
            output << indent.root.value
            position = indent.root.length
          else
            position = 0
          end
        else
          output << newline
          output << indent.value
          position = indent.length
        end
      else
        # Special case where the user has defined some way to get an extra doc
        # node that we don't explicitly support into the list. In this case
        # we're going to assume it's 0-width and just append it to the output
        # buffer.
        #
        # This is useful behavior for putting marker nodes into the list so that
        # you can know how things are getting mapped before they get printed.
        output << doc
      end
    end
  end

  # A convenience method used by a lot of the print tree node builders that
  # temporarily changes the target that the builders will append to.
  def with_target(target)
    previous_target, @target = @target, target
    yield
    @target = previous_target
  end

  private

  # This method returns a boolean as to whether or not the remaining commands
  # fit onto the remaining space on the current line. If we finish printing
  # all of the commands or if we hit a newline, then we return true. Otherwise
  # if we continue printing past the remaining space, we return false.
  def fits?(next_command, rest_commands, remaining)
    # This is the index in the remaining commands that we've handled so far.
    # We reverse through the commands and add them to the stack if we've run
    # out of nodes to handle.
    rest_index = rest_commands.length

    # This is our stack of commands, very similar to the commands list in the
    # print method.
    commands = [next_command]

    while remaining >= 0
      if commands.empty?
        return true if rest_index == 0

        rest_index -= 1
        commands << rest_commands[rest_index]
        next
      end

      indent, mode, doc = commands.pop

      case doc
      when Text
        remaining -= doc.width
      when Array
        doc.reverse_each { |part| commands << [indent, mode, part] }
      when Align
        commands << [indent.align(doc.indent), mode, doc.contents]
      when Group
        commands << [indent, doc.break? ? MODE_BREAK : mode, doc.contents]
      when Breakable
        if mode == MODE_FLAT
          remaining -= doc.width
          next
        end

        return true
      end
    end

    false
  end

  # A node in the print tree that represents plain content that cannot be broken
  # up (by default this assumes strings, but it can really be anything).
  class Text
    attr_reader :objs, :width

    def initialize
      @objs = []
      @width = 0
    end

    # Include +obj+ in the objects to be pretty printed, and increment
    # this Text object's total width by +width+
    def add(obj, width)
      @objs << obj
      @width += width
    end
  end

  # This object represents the current level of indentation within the printer.
  # It has the ability to generate new levels of indentation through the #align
  # and #indent methods.
  class IndentLevel
    attr_reader :genspace, :value, :length, :queue, :root

    def initialize(
      genspace:,
      value: genspace.call(0),
      length: 0,
      queue: [],
      root: nil
    )
      @genspace = genspace
      @value = value
      @length = length
      @queue = queue
      @root = root
    end

    def align(n)
      next_value = genspace.call(0)
      next_length = 0
      next_queue = [*queue, n]

      last_spaces = 0
      next_queue.each { |part| last_spaces += part }

      if last_spaces > 0
        next_value << genspace.call(last_spaces)
        next_length += last_spaces
      end

      IndentLevel.new(
        genspace: genspace,
        value: next_value,
        length: next_length,
        queue: next_queue,
        root: root
      )
    end
  end

  # A node in the print tree that represents aligning nested nodes to a certain
  # prefix width or string.
  class Align
    attr_reader :indent, :contents

    def initialize(indent:, contents: [])
      @indent = indent
      @contents = contents
    end
  end

  # A node in the print tree that represents a place in the buffer that the
  # content can be broken onto multiple lines.
  class Breakable
    attr_reader :separator, :width

    def initialize(separator = " ", width = separator.length, indent: true)
      @separator = separator
      @width = width
      @indent = indent
    end

    def indent?
      @indent
    end
  end

  # A node in the print tree that represents a group of items which the printer
  # should try to fit onto one line. This is the basic command to tell the
  # printer when to break. Groups are usually nested, and the printer will try
  # to fit everything on one line, but if it doesn't fit it will break the
  # outermost group first and try again. It will continue breaking groups until
  # everything fits (or there are no more groups to break).
  class Group
    attr_reader :depth, :contents

    def initialize(depth, contents: [])
      @depth = depth
      @contents = contents
      @break = false
    end

    def break
      @break = true
    end

    def break?
      @break
    end
  end

  # PrettyPrint::SingleLine is used by PrettyPrint.singleline_format
  #
  # It is passed to be similar to a PrettyPrint object itself, by responding to:
  # * #text
  # * #breakable
  # * #nest
  # * #group
  # * #flush
  # * #first?
  #
  # but instead, the output has no line breaks
  #
  class SingleLine
    # Create a PrettyPrint::SingleLine object
    #
    # Arguments:
    # * +output+ - String (or similar) to store rendered text. Needs to respond to '<<'
    # * +maxwidth+ - Argument position expected to be here for compatibility.
    #                This argument is a noop.
    # * +newline+ - Argument position expected to be here for compatibility.
    #               This argument is a noop.
    def initialize(output, maxwidth=nil, newline=nil)
      @output = output
    end

    # Add +obj+ to the text to be output.
    #
    # +width+ argument is here for compatibility. It is a noop argument.
    def text(obj, width=nil)
      @output << obj
    end

    # Appends +sep+ to the text to be output. By default +sep+ is ' '
    #
    # +width+ argument is here for compatibility. It is a noop argument.
    def breakable(sep=' ', width=nil, indent: nil)
      @output << sep
    end

    # Appends +separator+ to the output buffer. +width+ is a noop here for
    # compatibility.
    def fill_breakable(separator = " ", width = separator.length)
      @output << separator
    end

    # Takes +indent+ arg, but does nothing with it.
    #
    # Yields to a block.
    def nest(indent) # :nodoc:
      yield
    end

    # Opens a block for grouping objects to be pretty printed.
    #
    # Arguments:
    # * +indent+ - noop argument. Present for compatibility.
    # * +open_obj+ - text appended before the &blok. Default is ''
    # * +close_obj+ - text appended after the &blok. Default is ''
    # * +open_width+ - noop argument. Present for compatibility.
    # * +close_width+ - noop argument. Present for compatibility.
    def group(indent=nil, open_obj='', close_obj='', open_width=nil, close_width=nil)
      @output << open_obj
      yield
      @output << close_obj
    end

    # Method present for compatibility, but is a noop
    def flush # :nodoc:
    end
  end
end
