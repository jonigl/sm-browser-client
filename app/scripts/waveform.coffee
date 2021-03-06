AudioManager = require "./audio_manager"
React = require "react"
d3 = require "d3"
moment = require "moment"
require "moment-duration-format"

Segments = require "./segments"
Cursor = require "./cursor"
Selection = require "./selection"

Dispatcher = require "./dispatcher"

module.exports = class SM_Waveform
    constructor: (@target,@audio,@opts) ->
        @height = @opts.wave_height
        @preview_height = @opts.preview_height

        @_zooming = false

        @_segWidth = null

        @width  = @target.width()

        @_cursor = null

        Selection.on "change", =>
            @_drawInOutPoints()

            # if @selection.isValid()
            #     @_downloadLink.attr("href",@selection.download_link())
            #     @_download.show()
            #
            # else
            #     @_download.hide()

        # -- create our elements -- #

        @_preview = $ "<div/>"
        @_zoom = $ "<div/>"

        @target.append @_preview
        @target.append @_zoom

        # -- set up segments collection -- #

        Segments.Segments.once "reset", =>
            @_initCharts()
            @_updateFocusWaveform()

        Segments.Segments.on "add remove", =>
            @_setFullX()
            @_cachePreviewWave()
            @_updateFocusWaveform()
            @_drawPreview()

        # -- watch for play/pause -- #

        @_playing = null
        @audio.on "playhead", (ts) => @_drawPlayhead(ts)

        $(document).on "keyup", (e) =>
            console.log "keycode is ", e.keyCode
            # space bar OR k - Play/pause
            if e.keyCode == 32 or e.keyCode == 75
                # spacebar
                if @audio.playing()
                    console.log "Stopping"
                    @audio.stop()
                else
                    if ts = Cursor.get('ts')
                        console.log "Playing", ts
                        @audio.play ts
            # [ left bracket - set IN point
            else if e.keyCode == 219                
                @_setInPoint(Cursor.get('ts'))
            # ] right bracket - set OUT point
            else if e.keyCode == 221
                @_setOutPoint(Cursor.get('ts'))
            # esc - pause
            else if e.keyCode == 27
                if @audio.playing()
                    console.log "Stopping"
                    @audio.stop()
            # shift+j - Jump back 30 second                        
            else if e.shiftKey and e.which == 74
                if ts = Cursor.get('ts')
                    Dispatcher.dispatch actionType:"cursor-set", ts:new Date(ts.getTime() - 30000)
            # shift+l - Jump forward 30 second                        
            else if e.shiftKey and e.which == 76                
                if ts = Cursor.get('ts')
                    Dispatcher.dispatch actionType:"cursor-set", ts:new Date(ts.getTime() + 30000)
            # j - Jump back 5 seconds                    
            else if e.keyCode == 74
                if ts = Cursor.get('ts')
                    Dispatcher.dispatch actionType:"cursor-set", ts:new Date(ts.getTime() - 5000)
            # l - Jump forward 5 seconds
            else if e.keyCode == 76
                if ts = Cursor.get('ts')
                    Dispatcher.dispatch actionType:"cursor-set", ts:new Date(ts.getTime() + 5000)
                    
    #----------

    _click: (seg,evt,select,segWidth) ->
        d3m = d3.mouse(@_main.node())
        Dispatcher.dispatch actionType:"cursor-set", ts:@_x.invert(d3m[0])

    #----------

    _setInPoint: (ts) ->
        Dispatcher.dispatch actionType:"selection-set-in", ts:ts

    #----------

    _setOutPoint: (ts) ->
        Dispatcher.dispatch actionType:"selection-set-out", ts:ts

    #----------

    _setFullX: ->
        @_fullx = d3.time.scale().domain([Segments.Segments.first().get("ts"),Segments.Segments.last().get("end_ts")]).range([0,@width])


    #----------

    _initCharts: ->
        tthis = @

        @_previewIsBrushing = false

        # -- Scales -- #

        @_x = d3.time.scale()
        @_y = d3.scale.linear()

        @_x.domain([Segments.Focus.first().get("ts"),Segments.Focus.last().get("end_ts")]).rangeRound([0,@width])
        @_y.domain([-128,128]).rangeRound([-(@height / 2),@height / 2])

        @_px = d3.time.scale()
        @_pxIdx = d3.scale.linear()
        @_py = d3.scale.linear()

        @_cachePreviewWave()

        @_px.domain([Segments.Segments.first().get("ts"),Segments.Segments.last().get("end_ts")]).range([0,@width])
        @_pxIdx.domain([0,@_pwave.adapter.data.length-1]).rangeRound([0,@width])
        @_py.domain([-128,128]).rangeRound([-(@preview_height / 2),@preview_height / 2])

        @_setFullX()

        # -- axis labels -- #

        @_xAxis = d3.svg.axis().scale(@_x).orient("bottom")
        @_pxAxis = d3.svg.axis().scale(@_px).orient("bottom")

        # -- Preview Graph with Brushing -- #

        @_previewg = d3.select(@_preview[0]).append("svg").attr("class","preview").style(width:"100%",height:"#{@preview_height+50}px")
        #Available audio information in the waveform
        segStart = Segments.Segments.first()?.get("ts_actual")
        segEnd = Segments.Segments.last()?.get("end_ts_actual")
        @_previewg.append("foreignObject")
            .attr("class","available-audio")
            .attr("x", 0)
            .attr("y", 75)
            .attr("width", 410)
            .attr("height", 25)
            .append("xhtml:body")
            .append("xhtml:div")
            .attr("class","info-value")
            .html("<span class=\"info-title\">Available audio from</span> " + moment(segStart).format('MMM DD, h:mm:ssa') + " <span class=\"info-title\">to</span> " + moment(segEnd).format('MMM DD, h:mm:ssa'))
            
        @_brush = d3.svg.brush().x(@_px).extent(@_x.domain())
            .on "brushstart", =>
                @_previewIsBrushing = true
            .on "brushend", =>
                @_previewIsBrushing = false
                @_drawPreview()
            .on "brush", =>
                #console.log("zoom manipulated")
                # I clean markers when zoom (preview waveform) is manipulated
                Dispatcher.dispatch actionType:"selection-clear"
                if @_brush.empty()
                    # no brush selected, so focus all segments in our preview
                    @_x.domain @_px.domain()
                    Segments.Focus.reset Segments.Segments.selectDates @_x.domain()...
                else
                    @_x.domain @_brush.extent()
                    Segments.Focus.reset Segments.Segments.selectDates @_x.domain()...

                @_drawPreview()

                @_zoom.x(@_x)
                @_updateFocusWaveform()
                @_drawCursor()
                @_drawInOutPoints()

        @_previewArea = d3.svg.area()
            .x( (d) -> tthis._pxIdx(d) )
            .y0( (d) -> tthis._py(tthis._pwaveMin[d]) )
            .y1( (d) -> tthis._py(tthis._pwaveMax[d]) )

        @_previewPath = @_previewg.append("path")
            .attr("transform","translate(0,#{@preview_height / 2})")

        @_previewg.append("g")
            .attr("class","x brush")
            .call(@_brush)
            .selectAll("rect")
            .attr("y",-6)
            .attr("height",@preview_height + 7)

        @_pxAxis_s = @_previewg.append("g")
            .attr("class","x axis")
            .attr("transform","translate(0,#{@preview_height})")
            .call(@_pxAxis)

        @_drawPreview()

        # @_pzoom = d3.behavior.zoom().scaleExtent([1,1])
        # @_pzoom.x(@_px)
        # @_previewg.call(@_pzoom)

        # -- Focus Graph -- #

        @_main = d3.select(@_zoom[0]).append("svg").style(width:"100%",height:"#{@height+20}px")

        @_main.on("click", (d,i) ->
            console.log "click", tthis._zooming
            return if tthis._zooming
            tthis._click(d,d3.event,this))

        @_mainWave = @_main.append("g").attr("class","wave")


        @_xAxis_s = @_main.append("g")
            .attr("class","x axis")
            .attr("transform","translate(0,#{@height})")
            .call(@_xAxis)

        @_zoom = d3.behavior.zoom().scaleExtent([1,1])
        @_zoom.x(@_x)
        @_zoom.on "zoomstart", =>
                # this will get set true in zoom if we actually are moving.
                # clearing here gets us set for click
                @_zooming = false
            .on "zoom", =>
                @_zooming = true
                
                # -- validate target -- #

                t = @_zoom.translate()
                tx = t[0]

                if @_x(@_fullx.domain()[0]) > 0
                    tx -= @_x(@_fullx.domain()[0])
                else if @_x(@_fullx.domain()[1]) < @_x.range()[1]
                    tx -= @_x(@_fullx.domain()[1]) - @_x.range()[1]

                @_zoom.translate([tx,t[1]])

                # -- trigger updates -- #

                @_drawPreview()
                @_brush.extent @_x.domain()

                @_previewg.selectAll(".brush").call(@_brush)
                Segments.Focus.reset Segments.Segments.selectDates @_x.domain()...
                @_updateFocusWaveform()
                @_drawCursor()
                @_drawInOutPoints()

        @_main.call(@_zoom)

        @_markers = @_main.append("g").attr("class","markers")
        
        Cursor.on "change", =>
            @_drawCursor()

        true

    #----------

    _cachePreviewWave: ->
        @_pwave = Segments.Segments.previewWave()
        @_pwaveMin = @_pwave.min
        @_pwaveMax = @_pwave.max

    #----------

    # resample the given subsection of the preview wave to fit into the
    # domain that should be shown, then update the preview line with that
    # data
    _drawPreview: ->
        # should we make any changes to our domain?
        @_updatePreviewDomains()

        # only draw the visible portion of the preview
        @_previewPath.attr("d",@_previewArea([@_pxIdx.invert(0)..@_pxIdx.invert(@width)]))

        # update our axis
        @_pxAxis_s.call(@_pxAxis)

        @_brush.extent @_x.domain()
        @_previewg.selectAll(".brush").call(@_brush)

    #----------

    # preview domain should zoom to where our focus area is 50% of preview
    # width, stopping when we reach the max resolution of our preview
    _updatePreviewDomains: ->
        # if we're brushing, don't do any zooming, just allow scrolling
        if @_previewIsBrushing
            # if brush extent is near the edge of our domain, scroll the
            # domain to accomodate
            bext = @_brush.extent()
            pd = @_px.domain()

            adjustment = 0

            if @_px(bext[0]) / @width <= 0.02
                # attempt to scroll left
                adjustment = Number(bext[0]) - Number(@_px.invert(@width*0.02))

            else if @_px(bext[1]) / @width >= 0.98
                # attempt to scroll right
                adjustment = Number(bext[1]) - Number(@_px.invert(@width*0.98))

            ld = new Date( Number(pd[0]) + adjustment)
            rd = new Date( Number(pd[1]) + adjustment)
        else
            # -- zoom domains -- #

            targetWidth = @width / 1.5

            # ask @_x for the domain values that are 50% out in either direction
            ld = @_x.invert(-1*targetWidth)
            rd = @_x.invert(@width+targetWidth)

            # is the resolution too high?
            msecs = Number(rd) - Number(ld)

            pdata = Segments.Segments.previewWave().adapter.data

            mintime = pdata.samples_per_pixel / pdata.sample_rate * @width

            if msecs / 1000 < mintime
                # zoomed in too far... zoom out to our minimum time period
                add_secs = mintime - (msecs / 1000)
                #console.log "Adding #{add_secs} to preview"

                ld = new Date( Number(ld) - add_secs*1000 / 2 )
                rd = new Date( Number(rd) + add_secs*1000 / 2 )

        # clamp against values we actually have
        fulld = @_fullx.domain()

        if ld < fulld[0]
            correction = Number(fulld[0]) - Number(ld)
            ld = fulld[0]
            rd = new Date( Number(rd) + correction )

        if rd > fulld[1]
            correction = Number(rd) - Number(fulld[1])
            rd = fulld[1]
            ld = new Date( Math.max(( Number(ld) - correction ),Number(fulld[0])))

        ld = fulld[0] if ld < fulld[0]
        rd = fulld[1] if rd > fulld[1]

        # now convert these values into pixels in the preview waveform

        #console.log "sec_start = Math.floor((#{Number(ld)} - #{Number(fulld[0])}) / 1000)"
        #console.log "sec_end = Math.ceil((#{Number(rd)} - #{Number(fulld[0])}) / 1000)"
        sec_start = Math.floor((Number(ld) - Number(fulld[0])) / 1000)
        sec_end = Math.ceil((Number(rd) - Number(fulld[0])) / 1000)

        offset_start = Math.max(@_pwave.at_time(sec_start),@_pwave.offset_start)
        offset_end = Math.min(@_pwave.at_time(sec_end),@_pwave.offset_end-1)

        @_px.domain([ld,rd])
        @_pxIdx.domain([offset_start,offset_end])
        #@_brush.x(@_px)
        
    #----------

    _updateFocusWaveform: ->
        tthis = @
        
        # target sample rate is the duration of our x scale * sample rate / width
        d = @_x.domain()
        dur = (Number(d[1]) - Number(d[0])) / 1000
        targetRate = Math.ceil( dur * 44100 / @width )

        #console.log "updateFocusWaveform called. Target rate is #{targetRate} for #{@focus_segments.length} segments"

        segs = @_mainWave.selectAll(".segment").data( Segments.Focus.models, (s) -> s.id )

        segs.enter().append("g")
            .attr("class","segment")
            .attr("segment",(d) -> d.id)

        segs.exit().remove()

        segs
            .attr("transform", (d,i) ->
                "translate(#{ tthis._x( d.get("ts_actual") ) },#{ tthis.height / 2 })"
            ).each (d,i) ->
                s = d3.select(this)
                # is a re-render necessary?
                if Number(s.attr("targetRate")) != targetRate
                    #console.log "Need to redraw segment #{d.id} for #{targetRate} samples/pixel"
                    s.attr("targetRate",targetRate)
                    s.selectAll("*").remove()

                    pixels = (tthis._x( d.get("end_ts_actual") ) - tthis._x( d.get("ts_actual") ) || 1) + 1
                    #console.log "Segment will be #{pixels}px"
                    s.attr("pixels",pixels)

                    d.downsampled_wave pixels, (err,wave) =>
                        if pixels == 2
                            # draw a vertical line
                            s.append("line").attr("x1",0).attr("x2",0).attr("y1",wave.max[0]).attr("y2",wave.min[0])

                        else

                            wavearea = d3.svg.area()
                                .x( (d,i) -> i )
                                .y0( (d,i) -> tthis._y(wave.min[i]) )
                                .y1( (d,i) -> tthis._y(d) )

                            s.append("path").attr("d",wavearea( wave.max ))

        @_xAxis_s.call(@_xAxis)

    #----------

    _drawCursor: ->
        ts = Cursor.get('ts')
        
        if !ts
            @_markers.selectAll(".cursor").remove()
            @_previewg.selectAll(".cursor").remove()
            return true

        tthis = @

        # -- main waveform -- #

        c = @_markers.selectAll(".cursor").data([ts])

        c.enter().append("g")
            .attr("class","cursor")
            .append("path")
            
        @_markers.selectAll("foreignObject.cursor").remove()
        @_markers.append("foreignObject")
            .attr("class","cursor")
            .attr("x",tthis._x(ts) + 1)
            .attr("y", tthis.height - 25)
            .attr("width", 200)
            .attr("height", 25)
            .append("xhtml:body")
            .append("xhtml:div")
            .attr("class","info-value")
            .html("<span class=\"info-title\">></span> " + moment(ts).format("MMM DD, h:mm:ss.SSSa"))
                
        c.select("path")
            .attr("d", (d,i) -> "M#{tthis._x(d)},0v0,#{tthis.height}Z" )

        # -- preview waveform -- #

        pc = @_previewg.selectAll(".cursor").data([ts])

        pc.enter().append("g")
            .attr("class","cursor")
            .append("path")

        pc.select("path")
            .attr("d", (d,i) -> "M#{tthis._px(d)},0v0,#{tthis.preview_height}" )

    #----------

    _drawInOutPoints: ->
        tthis = @
        for p in ['in','out']
            s = @_markers.selectAll(".#{p}")
            
            if ts = Selection.get(p)
                s = s.data([ts])

                s.enter().append("g")
                    .attr("class",p)
                    .append("path")

                s.select("path")
                    .attr("d", (ts) -> "M#{tthis._x(ts)},0v0,#{tthis.height}")
                @_markers.selectAll("foreignObject.out-time").remove()
                if p == 'in'
                    @_markers.append("foreignObject")
                    .attr("class","in-time")
                    .attr("x",tthis._x(ts) - 200)
                    .attr("y", 0    )
                    .attr("width", 200)
                    .attr("height", 50)
                    .append("xhtml:body")
                    .append("xhtml:div")
                    .attr("class","info-value")
                    .html("<span class=\"info-title\">IN</span> "+moment(ts).format("MMM DD, h:mm:ss.SSSa"))
                if p == 'out'
                    @_markers.append("foreignObject")
                    .attr("class","out-time")
                    .attr("x",tthis._x(ts))
                    .attr("y", 0    )
                    .attr("width", 200)
                    .attr("height", 50)
                    .append("xhtml:body")
                    .append("xhtml:div")
                    .attr("class","info-value")
                    .html("<span class=\"info-title\">OUT</span> "+moment(ts).format("MMM DD, h:mm:ss.SSSa"))
            else
                s.remove()      
                                          

        # -- selection area -- #
 
        area = @_markers.selectAll(".inout")

        if Selection.isValid()
            inx = @_x(Selection.get("in"))
            outx = @_x(Selection.get("out"))
            area.remove()
            @_markers.append("path")
                .attr("class","inout")
                .attr("d","M#{inx},0L#{outx},0L#{outx},#{@height}L#{inx},#{@height}Z")
                
            @_markers.append("foreignObject")
                .attr("class","area-duration")
                .attr("x",tthis._x(ts) - outx + inx )
                .attr("y", tthis.height-50)
                .attr("width", 200)
                .attr("height", 50)
                .append("xhtml:body")
                .append("xhtml:div")
                .attr("class","info-value")
                .html("<span class=\"info-title\">Duration</span> "+moment.duration(moment(Selection.get("out")).diff(Selection.get("in"))).format("h [hrs], m [min], s [sec], S [ms]"))
        else
            area.remove()
            @_markers.selectAll("foreignObject.area-duration").remove()
            @_markers.selectAll("foreignObject.in-time").remove()
            @_markers.selectAll("foreignObject.out-time").remove()

    #----------

    _drawPlayhead: (ts) ->
        tthis = @

        if ts
            c = @_markers.selectAll(".playhead").data([ts])

            c.enter().append("g")
                .attr("class","playhead")
                .append("path")

            c.select("path")
                .attr("d", (ts) -> "M#{tthis._x(ts)},0v0,#{tthis.height}")
        else
            @_markers.selectAll(".playhead").remove()

    #----------
