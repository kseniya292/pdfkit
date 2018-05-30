###
PDFDocument - represents an entire PDF document
By Devon Govett
###

stream = require 'stream'
fs = require 'fs'
PDFObject = require './object'
PDFReference = require './reference'
PDFPage = require './page'
PDFOutline = require './outline'

class PDFDocument extends stream.Readable
  constructor: (@options = {}) ->
    super

    # PDF version
    @version = 1.3

    # Whether streams should be compressed
    @compress = @options.compress ? yes

    @_pageBuffer = []
    @_pageBufferStart = 0

    # The PDF object store
    @_offsets = []
    @_waiting = 0
    @_ended = false
    @_offset = 0

    @_root = @ref
      Type: 'Catalog'
      Pages: @ref
        Type: 'Pages'
        Count: 0
        Kids: []

    if @options.hasOutlines
      @_root.data['PageMode'] = 'UseOutlines'
      @_root.data['Outlines'] = @ref
          Type: 'Outlines'
          Count: 0

    @root_outlines = @_root.data['Outlines'] 

    # The current page
    @page = null

    # Outlines data structures
    @outlines = []  # a multitier tree, represented by lists ( [] )
    @cur       = @outlines       # current level list
    @levelHead = @root_outlines  # head of current level list
    @levs  = []  # stack of sublevel lists heads
    @prevs = []  # stack of sublevel lists

    # Initialize mixins
    @initColor()
    @initVector()
    @initFonts()
    @initText()
    @initImages()

    # Initialize the metadata
    @info =
      Producer: 'PDFKit'
      Creator: 'PDFKit'
      CreationDate: new Date()

    if @options.info
      for key, val of @options.info
        @info[key] = val

    # Write the header
    # PDF version
    @_write "%PDF-#{@version}"

    # 4 binary chars, as recommended by the spec
    @_write "%\xFF\xFF\xFF\xFF"

    # Add the first page
    if @options.autoFirstPage isnt false
      @addPage()

  mixin = (methods) =>
    for name, method of methods
      this::[name] = method

  # Load mixins
  mixin require './mixins/color'
  mixin require './mixins/vector'
  mixin require './mixins/fonts'
  mixin require './mixins/text'
  mixin require './mixins/images'
  mixin require './mixins/annotations'

  addPage: (options = @options) ->
    # end the current page if needed
    @flushPages() unless @options.bufferPages

    # create a page object
    @page = new PDFPage(this, options)
    @_pageBuffer.push(@page)

    # add the page to the object store
    pages = @_root.data.Pages.data
    pages.Kids.push @page.dictionary
    pages.Count++

    # reset x and y coordinates
    @x = @page.margins.left
    @y = @page.margins.top

    # flip PDF coordinate system so that the origin is in
    # the top left rather than the bottom left
    @_ctm = [1, 0, 0, 1, 0, 0]
    @transform 1, 0, 0, -1, 0, @page.height

    @emit('pageAdded')

    return this

  bufferedPageRange: ->
    return { start: @_pageBufferStart, count: @_pageBuffer.length }

  switchToPage: (n) ->
    unless page = @_pageBuffer[n - @_pageBufferStart]
      throw new Error "switchToPage(#{n}) out of bounds, current buffer covers pages #{@_pageBufferStart} to #{@_pageBufferStart + @_pageBuffer.length - 1}"

    @page = page

  flushPages: ->
    # this local variable exists so we're future-proof against
    # reentrant calls to flushPages.
    pages = @_pageBuffer
    @_pageBuffer = []
    @_pageBufferStart += pages.length
    for page in pages
      page.end()

    return

  isRoot: () ->
    return @prevs.length == 0

  addOutline: (title, dest, options) ->

    if not @options.hasOutlines
        return this

    prevNode = null
    if @isRoot()
        parent = @root_outlines
    else
        parent = @levelHead.dictionary

    if @cur.length > 0  # can be on Root level
        prevNode = @cur[@cur.length-1]
        if prevNode instanceof Array # prev is a sublevel list
            prevNode = @cur[@cur.length-2]  # there *must* be an element before

    # create an outline object
    outline = new PDFOutline(this, parent, title, dest, options)
    
    # update list header info
    if @outlines.length == 0  # init root level list
        @root_outlines.data['First'] = outline.dictionary

    parent.data['Last'] = outline.dictionary   # can be root level
    parent.data['Count']++

    if prevNode != null   # not first in the list
        outline.dictionary.data['Prev']  = prevNode.dictionary
        prevNode.dictionary.data['Next'] = outline.dictionary

    # add to the current level list
    @cur.push outline

    @emit('outlineAdded')

    return this

  endOutlines: (outlines) ->
    for outline in outlines
      if outline instanceof Array
        @endOutlines(outline)
      else
        outline.dictionary.end()

  ref: (data) ->
    ref = new PDFReference(this, @_offsets.length + 1, data)
    @_offsets.push null # placeholder for this object's offset once it is finalized
    @_waiting++
    return ref

  _read: ->
      # do nothing, but this method is required by node

  _write: (data) ->
    unless Buffer.isBuffer(data)
      data = new Buffer(data + '\n', 'binary')

    @push data
    @_offset += data.length

  addContent: (data) ->
    @page.write data
    return this

  _refEnd: (ref) ->
    @_offsets[ref.id - 1] = ref.offset
    if --@_waiting is 0 and @_ended
      @_finalize()
      @_ended = false

  write: (filename, fn) ->
    # print a deprecation warning with a stacktrace
    err = new Error '
      PDFDocument#write is deprecated, and will be removed in a future version of PDFKit.
      Please pipe the document into a Node stream.
    '

    console.warn err.stack

    @pipe fs.createWriteStream(filename)
    @end()
    @once 'end', fn

  output: (fn) ->
    # more difficult to support this. It would involve concatenating all the buffers together
    throw new Error '
      PDFDocument#output is deprecated, and has been removed from PDFKit.
      Please pipe the document into a Node stream.
    '

  end: ->
    @flushPages()
    @_info = @ref()
    for key, val of @info
      if typeof val is 'string'
        val = new String val

      @_info.data[key] = val

    @_info.end()

    for name, font of @_fontFamilies
      font.finalize()

    @_root.end()
    @_root.data.Pages.end()
    @_root.data.Outlines.end()
    @endOutlines(@outlines)

    if @_waiting is 0
      @_finalize()
    else
      @_ended = true

  _finalize: (fn) ->
    # generate xref
    xRefOffset = @_offset
    @_write "xref"
    @_write "0 #{@_offsets.length + 1}"
    @_write "0000000000 65535 f "

    for offset in @_offsets
      offset = ('0000000000' + offset).slice(-10)
      @_write offset + ' 00000 n '

    # trailer
    @_write 'trailer'
    @_write PDFObject.convert
      Size: @_offsets.length + 1
      Root: @_root
      Info: @_info

    @_write 'startxref'
    @_write "#{xRefOffset}"
    @_write '%%EOF'

    # end the stream
    @push null

  toString: ->
    "[object PDFDocument]"

module.exports = PDFDocument
