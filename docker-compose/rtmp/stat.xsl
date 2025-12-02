<?xml version="1.0" encoding="utf-8" ?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html"/>
<xsl:template match="/">
<html>
<head>
<title>RTMP Statistics</title>
<style>
body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
h1 { color: #333; }
h2 { color: #666; }
.stream { background: white; padding: 15px; margin: 10px 0; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
.label { font-weight: bold; color: #333; }
.value { color: #666; }
</style>
</head>
<body>
<h1>RTMP Server Statistics</h1>
<xsl:apply-templates select="rtmp/server"/>
</body>
</html>
</xsl:template>
<xsl:template match="server">
<h2>Server Info</h2>
<p>Uptime: <xsl:value-of select="uptime"/> seconds</p>
<xsl:apply-templates select="application"/>
</xsl:template>
<xsl:template match="application">
<h3>Application: <xsl:value-of select="name"/></h3>
<p>Active streams: <xsl:value-of select="count(live/stream)"/></p>
<xsl:apply-templates select="live/stream"/>
</xsl:template>
<xsl:template match="stream">
<div class="stream">
<p><span class="label">Stream:</span> <span class="value"><xsl:value-of select="name"/></span></p>
<p><span class="label">Clients:</span> <span class="value"><xsl:value-of select="nclients"/></span></p>
<p><span class="label">Bandwidth In:</span> <span class="value"><xsl:value-of select="format-number(bw_in div 1024, #.##)"/> Kbps</span></p>
<p><span class="label">Bandwidth Out:</span> <span class="value"><xsl:value-of select="format-number(bw_out div 1024, #.##)"/> Kbps</span></p>
<p><span class="label">Video:</span> <span class="value"><xsl:value-of select="meta/video/codec"/> <xsl:value-of select="meta/video/width"/>x<xsl:value-of select="meta/video/height"/></span></p>
<p><span class="label">Audio:</span> <span class="value"><xsl:value-of select="meta/audio/codec"/> <xsl:value-of select="meta/audio/sample_rate"/>Hz</span></p>
</div>
</xsl:template>
</xsl:stylesheet>