//
//  GameViewController.mm
//  Wave
//
//  Created by Leon Rinkel on 05.09.23.
//

#import "AppViewController.hh"

#include <vector>
#include <string>
#include <sstream>

#include <stdint.h>

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"

#include "implot.h"

extern int ImFormatString(char* buf, size_t buf_size, const char* fmt, ...);

struct AppLog {
    ImGuiTextBuffer Buf;
    ImVector<int> LineOffsets;
    bool AutoScroll;

    AppLog() {
        AutoScroll = true;
        Clear();
    }

    void Clear() {
        Buf.clear();
        LineOffsets.clear();
        LineOffsets.push_back(0);
    }

    void AddLog(const char* fmt, ...) IM_FMTARGS(2) {
        int old_size = Buf.size();
        
        va_list args;
        va_start(args, fmt);
        Buf.appendfv(fmt, args);
        va_end(args);
        
        for (int new_size = Buf.size(); old_size < new_size; old_size++) {
            if (Buf[old_size] == '\n')
                LineOffsets.push_back(old_size + 1);
        }
    }

    void Draw(const char* title) {
        if (!ImGui::Begin(title)) {
            ImGui::End();
            return;
        }

        if (ImGui::BeginPopup("options")) {
            ImGui::Checkbox("auto scroll", &AutoScroll);
            ImGui::EndPopup();
        }
        
        if (ImGui::Button("options")) {
            ImGui::OpenPopup("options");
        }
        
        ImGui::SameLine();
        bool clear = ImGui::Button("clear");
        ImGui::SameLine();
        bool copy = ImGui::Button("copy");

        ImGui::Separator();

        if (ImGui::BeginChild("scrolling", ImVec2(0, 0), false, ImGuiWindowFlags_HorizontalScrollbar)) {
            if (clear) Clear();
            if (copy) ImGui::LogToClipboard();

            ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 0));
            const char* buf = Buf.begin();
            const char* buf_end = Buf.end();
            
            ImGuiListClipper clipper;
            clipper.Begin(LineOffsets.Size);
            while (clipper.Step()) {
                for (int line_no = clipper.DisplayStart; line_no < clipper.DisplayEnd; line_no++) {
                    const char* line_start = buf + LineOffsets[line_no];
                    const char* line_end = (line_no + 1 < LineOffsets.Size) ? (buf + LineOffsets[line_no + 1] - 1) : buf_end;
                    ImGui::TextUnformatted(line_start, line_end);
                }
            }
            clipper.End();

            ImGui::PopStyleVar();

            if (AutoScroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY()) {
                ImGui::SetScrollHereY(1.0f);
            }
        }
        
        ImGui::EndChild();
        ImGui::End();
    }
};

struct ScrollingBuffer {
    int MaxSize;
    int Offset;
    ImVector<ImVec2> Data;
    
    ScrollingBuffer(int max_size = 2000) {
        MaxSize = max_size;
        Offset = 0;
        Data.reserve(MaxSize);
    }
    
    void AddPoint(float x, float y) {
        if (Data.size() < MaxSize) {
            Data.push_back(ImVec2(x,y));
        } else {
            Data[Offset] = ImVec2(x,y);
            Offset = (Offset + 1) % MaxSize;
        }
    }
    
    void Erase() {
        if (Data.size() > 0) {
            Data.shrink(0);
            Offset = 0;
        }
    }
};

struct WavChunk {
    char id[4];
    uint32_t size;
};

struct WavRiff {
    char id[4];
    uint32_t size;
    char format[4];
};

struct WavFmt {
    char id[4];
    uint32_t size;
    uint16_t audioFormat;
    uint16_t numChannels;
    uint32_t sampleRate;
    uint32_t byteRate;
    uint16_t blockAlign;
    uint16_t bitsPerSample;
};

@implementation AppViewController
{
    struct AppLog log;
    
    bool loadedFile;
    FILE* inFile; /* file descriptor of the input wav file */
    off_t off; /* offset in the input wav file */
    size_t nread; /* bytes of data read */
    struct WavChunk chunk; /* chunk read/written from/to wav file */
    struct WavRiff riff; /* riff chunk read/written from/to wav file */
    struct WavFmt fmt; /* fmt chunk read/written from/to wav file */
    size_t dataSize; /* size of data chunk */
    unsigned long nsamples; /* number of samples the file contains */
    int nseconds; /* length of file in seconds */
    void* data; /* contents of data chunk */
}

- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];
    
    if (!self.device) {
        NSLog(@"Metal is not supported");
        abort();
    }
    
    IMGUI_CHECKVERSION();
    
    ImGui::CreateContext();
    ImPlot::CreateContext();
    
    ImGuiIO& io = ImGui::GetIO();
    (void)io;
    
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;
    //io.IniFilename = nullptr;
    
    ImGui::StyleColorsDark();
    ImGuiStyle& style = ImGui::GetStyle();
    if (io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) {
        style.WindowRounding = 0.0f;
        style.Colors[ImGuiCol_WindowBg].w = 1.0f;
    }
    
    ImGui_ImplMetal_Init(_device);
    
    return self;
}

- (MTKView *)mtkView {
    return (MTKView *)self.view;
}

- (void)loadView {
    self.view = [[MTKView alloc] initWithFrame:CGRectMake(0, 0, 1080, 720)];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.mtkView.device = self.device;
    self.mtkView.delegate = self;
    
    ImGui_ImplOSX_Init(self.view);
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)drawInMTKView:(MTKView *)view {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = view.bounds.size.width;
    io.DisplaySize.y = view.bounds.size.height;
    
    CGFloat framebufferScale = view.window.screen.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    io.DisplayFramebufferScale = ImVec2(framebufferScale, framebufferScale);
    
    id <MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    
    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor == nil) {
        [commandBuffer commit];
        return;
    }
    
    ImGui_ImplMetal_NewFrame(renderPassDescriptor);
    ImGui_ImplOSX_NewFrame(view);
    ImGui::NewFrame();
    
    ImGui::DockSpaceOverViewport(ImGui::GetMainViewport());
    
    //ImGui::ShowDemoWindow();
    //ImPlot::ShowDemoWindow();
    
    [self logWindow];
    [self loadWindow];
    [self playerWindow];
    [self waveformWindow];
    
    for (int channel = 0; channel < self.player.numberOfChannels; channel++) {
        [self channelPowerLevel:channel];
    }
    
    ImGui::Render();
    ImDrawData *drawData = ImGui::GetDrawData();
    
    static ImVec4 clearColor = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(clearColor.x * clearColor.w, clearColor.y * clearColor.w, clearColor.z * clearColor.w, clearColor.w);
    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    [renderEncoder pushDebugGroup:@"Dear ImGui rendering"];
    ImGui_ImplMetal_RenderDrawData(drawData, commandBuffer, renderEncoder);
    [renderEncoder popDebugGroup];
    [renderEncoder endEncoding];
    
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
    
    if (io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) {
        ImGui::UpdatePlatformWindows();
        ImGui::RenderPlatformWindowsDefault();
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)viewWillAppear {
    [super viewWillAppear];
    self.view.window.delegate = self;
}

- (void)windowWillClose:(NSNotification *)notification {
    ImGui_ImplMetal_Shutdown();
    ImGui_ImplOSX_Shutdown();
    
    ImPlot::DestroyContext();
    ImGui::DestroyContext();
}

- (void)logWindow {
    ImGui::SetNextWindowSize(ImVec2(500, 400), ImGuiCond_FirstUseEver);
    if (!ImGui::Begin("logger")) {
        ImGui::End();
        return;
    }
    
    ImGui::End();
    
    log.Draw("logger");
}

- (void)loadWindow {
    static bool chooseDisabled;
    static bool loadDisabled;
    
    static unsigned long long fileSize;
    
    if (!ImGui::Begin("loader", NULL, ImGuiWindowFlags_AlwaysAutoResize)) {
        ImGui::End();
        return;
    }
    
    chooseDisabled = !!self.file;
    if (chooseDisabled) ImGui::BeginDisabled();
    if (ImGui::Button("choose file") && !chooseDisabled) {
        NSOpenPanel* openPanel = [NSOpenPanel openPanel];
        
        NSArray* types = [NSArray arrayWithObject:[UTType typeWithFilenameExtension:@"wav"]];
        [openPanel setAllowedContentTypes:types];
        [openPanel setAllowsMultipleSelection: NO];
        [openPanel setCanChooseDirectories:NO];
        [openPanel setCanCreateDirectories:NO];
        [openPanel setCanChooseFiles:YES];
        
        [openPanel beginWithCompletionHandler:^(NSInteger result) {
            if (result == NSModalResponseOK) {
                self.file = [openPanel URLs].firstObject;
                self->log.AddLog("[%10.6f] file chosen %s\n", ImGui::GetTime(), self.file.path.UTF8String);
                
                fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:self.file.path error:nil] fileSize];
            }
        }];
    } else if (chooseDisabled) ImGui::EndDisabled();
    
    ImGui::SameLine();
    
    loadDisabled = !self.file || loadedFile;
    if (loadDisabled) ImGui::BeginDisabled();
    if (ImGui::Button("open file") && !loadDisabled) {
        log.AddLog("[%10.6f] opening file %s\n", ImGui::GetTime(), self.file.path.UTF8String);
        
        self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:self.file error:nil];
        self.player.enableRate = YES;
        self.player.meteringEnabled = YES;
        [self.player prepareToPlay];
        
        // open the input file
        inFile = fopen(self.file.path.UTF8String, "r");
        if (inFile == NULL) {
            log.AddLog("[%10.6f] unable to open file: %s\n", ImGui::GetTime(), strerror(errno));
            goto cleanup;
        }
        
        // read input file chunk by chunk
        while (
               riff.size == 0 || /* size of file not known yet or */
               off < riff.size + 8 /* offset not at the end yet */
               ) {
                   // seek in file
                   if (fseek(inFile, off, SEEK_SET) != 0) {
                       log.AddLog("[%10.6f] unable to seek in file: %s\n", ImGui::GetTime(), strerror(errno));
                       goto cleanup;
                   }
                   
                   // read next chunk from file
                   nread = fread(&chunk, sizeof(struct WavChunk), 1, inFile);
                   if (nread != 1) {
                       log.AddLog("[%10.6f] unable to read chunk from file\n", ImGui::GetTime());
                       goto cleanup;
                   }
                   
                   log.AddLog("[%10.6f] chunk id=%.4s size=%d\n", ImGui::GetTime(), chunk.id, chunk.size);
                   
                   // check for known chunk types
                   if (strncmp(chunk.id, "RIFF", sizeof(chunk.id)) == 0) {
                       // this is a riff type chunk
                       log.AddLog("[%10.6f] this is a riff type chunk\n", ImGui::GetTime());
                       
                       // go back to start of riff chunk
                       if (fseek(inFile, off, SEEK_SET) != 0) {
                           log.AddLog("[%10.6f] unable to seek in file: %s\n", ImGui::GetTime(), strerror(errno));
                           goto cleanup;
                       }
                       
                       // read riff chunk
                       nread = fread(&riff, sizeof(struct WavRiff), 1, inFile);
                       if (nread != 1) {
                           log.AddLog("[%10.6f] unable to read riff chunk from file\n", ImGui::GetTime());
                           goto cleanup;
                       }
                       
                       log.AddLog("[%10.6f] riff format=%.4s\n", ImGui::GetTime(), riff.format);
                       
                       // increment offset to next chunk
                       off += sizeof(struct WavRiff);
                   } else if (strncmp(chunk.id, "fmt ", sizeof(chunk.id)) == 0) {
                       // this is a fmt type chunk
                       log.AddLog("[%10.6f] this is a fmt type chunk\n", ImGui::GetTime());
                       
                       // go back to start of fmt chunk
                       if (fseek(inFile, off, SEEK_SET) != 0) {
                           log.AddLog("[%10.6f] unable to seek in file: %s\n", ImGui::GetTime(), strerror(errno));
                           goto cleanup;
                       }
                       
                       // read fmt chunk
                       nread = fread(&fmt, sizeof(struct WavFmt), 1, inFile);
                       if (nread != 1) {
                           log.AddLog("[%10.6f] unable to read fmt chunk from file\n", ImGui::GetTime());
                           goto cleanup;
                       }
                       
                       log.AddLog("[%10.6f] fmt.audio_format=%d\n", ImGui::GetTime(), fmt.audioFormat);
                       log.AddLog("[%10.6f] fmt.num_channels=%d\n", ImGui::GetTime(), fmt.numChannels);
                       log.AddLog("[%10.6f] fmt.sample_rate=%d\n", ImGui::GetTime(), fmt.sampleRate);
                       log.AddLog("[%10.6f] fmt.byte_rate=%d\n", ImGui::GetTime(), fmt.byteRate);
                       log.AddLog("[%10.6f] fmt.block_align=%d\n", ImGui::GetTime(), fmt.blockAlign);
                       log.AddLog("[%10.6f] fmt.bits_per_sample=%d\n", ImGui::GetTime(), fmt.bitsPerSample);
                       
                       // increment offset to next chunk
                       off += chunk.size + 8;
                   } else if (strncmp(chunk.id, "LIST", sizeof(chunk.id)) == 0) {
                       log.AddLog("[%10.6f] skipping list type chunk\n", ImGui::GetTime());
                       off += chunk.size + 8;
                   } else if (strncmp(chunk.id, "data", sizeof(chunk.id)) == 0) {
                       // this is a data type chunk
                       log.AddLog("[%10.6f] this is a data type chunk\n", ImGui::GetTime());
                       
                       // allocate mem for data
                       data = (void*) malloc(chunk.size);
                       dataSize = chunk.size;
                       
                       // read contents of data chunk
                       nread = fread(data, chunk.size, 1, inFile);
                       if (nread != 1) {
                           log.AddLog("[%10.6f] unable to read data chunk from file\n", ImGui::GetTime());
                           goto cleanup;
                       }
                       
                       off += chunk.size + 8;
                   } else {
                       // don't know this chunk type
                       log.AddLog("[%10.6f] unknown chunk type \n", ImGui::GetTime());
                       break;
                   }
               }
        
        // calculate some useful values
        nsamples = dataSize / fmt.numChannels / (fmt.bitsPerSample / 8);
        nseconds = round(((double) nsamples) / ((double) fmt.sampleRate));
        
        log.AddLog("[%10.6f] nsamples=%lu nseconds=%d\n", ImGui::GetTime(), nsamples, nseconds);
        
        // only implemented for 16 bit stereo pcm
        if (
            fmt.bitsPerSample != 16 ||
            fmt.audioFormat != 1 ||
            fmt.numChannels != 2
        ) {
            log.AddLog("[%10.6f] unsupported format\n", ImGui::GetTime());
            goto cleanup;
        }
    
    cleanup:
        
        // TODO: free data somewhere
        /*if (data != NULL) {
            free(data);
        }*/
        
        if (inFile != NULL) {
            fclose(inFile);
        }
        
        loadedFile = true;
    } else if (loadDisabled) ImGui::EndDisabled();
    
    ImGui::Separator();
    
    ImGui::LabelText("file", "%s", (self.file) ? [self.file lastPathComponent].UTF8String : "(null)");
    ImGui::LabelText("size [bytes]", "%llu", fileSize);
    
    ImGui::LabelText("audio format", "%d", fmt.audioFormat);
    ImGui::LabelText("num channels", "%d", fmt.numChannels);
    ImGui::LabelText("sample rate [hz]", "%d", fmt.sampleRate);
    ImGui::LabelText("byte rate", "%d", fmt.byteRate);
    ImGui::LabelText("bits per sample", "%d", fmt.bitsPerSample);
    
    ImGui::End();
}

- (void)playerWindow {
    static bool playDisabled;
    static bool pauseDisabled;
    
    static float progress = 0.0f;
    static float volume = 0.0f;
    static float pan = 0.0f;
    static float rate = 0.0f;
    
    if (!ImGui::Begin("player", NULL, ImGuiWindowFlags_AlwaysAutoResize)) {
        ImGui::End();
        return;
    }
    
    playDisabled = !loadedFile || self.player.isPlaying;
    if (playDisabled) ImGui::BeginDisabled();
    if (ImGui::Button("play") && !playDisabled) {
        [self.player play];
        log.AddLog("[%10.6f] started playing\n", ImGui::GetTime());
    }
    if (playDisabled) ImGui::EndDisabled();
    
    ImGui::SameLine();
    
    pauseDisabled = !loadedFile || !self.player.isPlaying;
    if (pauseDisabled) ImGui::BeginDisabled();
    if (ImGui::Button("pause") && !pauseDisabled) {
        [self.player pause];
        log.AddLog("[%10.6f] paused playing\n", ImGui::GetTime());
    }
    if (pauseDisabled) ImGui::EndDisabled();
    
    ImGui::Separator();
    
    ImGui::LabelText("current time [s]", "%f", (self.player) ? [self.player currentTime] : 0.0f);
    ImGui::LabelText("duration [s]", "%f", (self.player) ? [self.player duration] : 0.0f);
    ImGui::LabelText("is playing", "%d", (self.player) ? [self.player isPlaying] : 0);
    
    ImGui::SliderFloat("progress", &progress, 0.0f, 1.0f);
    if (ImGui::IsItemActive()) {
        self.player.currentTime = progress * [self.player duration];
    } else {
        progress = [self.player currentTime] / [self.player duration];
    }
    
    ImGui::SliderFloat("volume", &volume, 0.0f, 1.0f);
    if (ImGui::IsItemActive()) {
        self.player.volume = volume;
    } else {
        volume = [self.player volume];
    }
    
    ImGui::SliderFloat("pan", &pan, -1.0f, 1.0f);
    if (ImGui::IsItemActive()) {
        self.player.pan = pan;
    } else {
        pan = [self.player pan];
    }
    
    ImGui::SliderFloat("rate", &rate, -0.5f, 2.0f);
    if (ImGui::IsItemActive()) {
        self.player.rate = rate;
    } else {
        rate = [self.player rate];
    }
    
    [self.player updateMeters];
    
    ImGui::End();
}

- (void)waveformWindow {
    static bool waveformDisabled;
    static float windowSeconds = 1.0f;
    static int windowWidth;
    static double* time = NULL;
    static double* leftChannel = NULL;
    static double* rightChannel = NULL;
    static float position;
    static int offset;

    if (loadedFile && time == NULL) {
        windowWidth = round(windowSeconds * fmt.sampleRate);

        time = (double*) malloc(sizeof(double) * windowWidth);
        leftChannel = (double*) malloc(sizeof(double) * windowWidth);
        rightChannel = (double*) malloc(sizeof(double) * windowWidth);
    }
    
    if (!ImGui::Begin("waveform")) {
        ImGui::End();
        return;
    }
    
    waveformDisabled = !loadedFile;
    
    if (waveformDisabled) ImGui::BeginDisabled();
    ImGui::SliderFloat("window [s]", &windowSeconds, 0.001, 3);
    if (ImGui::IsItemActive()) {
        windowWidth = round(windowSeconds * fmt.sampleRate);
        
        time = (double*) realloc(time, sizeof(double) * windowWidth);
        leftChannel = (double*) realloc(leftChannel, sizeof(double) * windowWidth);
        rightChannel = (double*) realloc(rightChannel, sizeof(double) * windowWidth);
    }
    if (waveformDisabled) ImGui::EndDisabled();

    position = [self.player currentTime] / [self.player duration];
    offset = position * nsamples;
    
    int startSample = offset - windowWidth / 2;
    int sampleIndex = startSample;
    int bufferIndex = 0;
    while (sampleIndex < 0) {
        time[bufferIndex] = ((double) (startSample + bufferIndex)) / ((double) fmt.sampleRate);
        leftChannel[bufferIndex] = 0;
        rightChannel[bufferIndex] = 0;

        sampleIndex++;
        bufferIndex++;
    }
    while (bufferIndex < windowWidth) {
        time[bufferIndex] = ((double) sampleIndex) / ((double) fmt.sampleRate);
        
        // left and right channel are interleaved
        leftChannel[bufferIndex] = ((double) *(((int16_t*) data) + 0 + sampleIndex * fmt.numChannels)) / ((double) INT16_MAX);
        rightChannel[bufferIndex] = ((double) *(((int16_t*) data) + 1 + sampleIndex * fmt.numChannels)) / ((double) INT16_MAX);
        
        sampleIndex++;
        bufferIndex++;
    }
    
    if (!waveformDisabled && ImPlot::BeginSubplots("##waveform", 2, 1, ImVec2(ImGui::GetWindowWidth() - 20, ImGui::GetWindowHeight() - 70))) {
        double markers[] = { time[windowWidth / 2] };
        
        if (ImPlot::BeginPlot("left channel", ImVec2(), ImPlotFlags_NoLegend)) {
            ImPlot::SetupAxes("time", nullptr, ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickLabels, ImPlotAxisFlags_None);
            ImPlot::SetupAxisLimits(ImAxis_X1, time[0], time[windowWidth - 1], ImGuiCond_Always);
            ImPlot::SetupAxisLimits(ImAxis_Y1, -1.0f, +1.0f);
            
            ImPlot::PlotLine("left channel", time, leftChannel, windowWidth, 0, 0, sizeof(double));
            ImPlot::PlotInfLines("##marker", markers, 1);
            
            ImPlot::EndPlot();
        }
        
        if (ImPlot::BeginPlot("right channel", ImVec2(), ImPlotFlags_NoLegend)) {
            ImPlot::SetupAxes("time", nullptr, ImPlotAxisFlags_None, ImPlotAxisFlags_None);
            ImPlot::SetupAxisLimits(ImAxis_X1, time[0], time[windowWidth - 1], ImGuiCond_Always);
            ImPlot::SetupAxisLimits(ImAxis_Y1, -1.0f, +1.0f);
            
            ImPlot::PlotLine("right channel", time, rightChannel, windowWidth, 0, 0, sizeof(double));
            ImPlot::PlotInfLines("##marker", markers, 1);
            
            ImPlot::EndPlot();
        }
        
        ImPlot::EndSubplots();
    }
    
    ImGui::End();
}

- (void)channelPowerLevel:(int)channel {
    static std::vector<std::string> windowTitles;
    if (windowTitles.size() != self.player.numberOfChannels) {
        windowTitles.resize(self.player.numberOfChannels);
        
        for (int i = 0; i < self.player.numberOfChannels; i++) {
            std::stringstream ss;
            ss << "metering channel " << i;
            windowTitles[i] = ss.str();
        }
    }
    
    static float t = 0.0f;
    t += ImGui::GetIO().DeltaTime;
    
    static std::vector<ScrollingBuffer> sdata_avg_power;
    static std::vector<ScrollingBuffer> sdata_peak_power;
    if (
        sdata_avg_power.size() != self.player.numberOfChannels ||
        sdata_peak_power.size() != self.player.numberOfChannels
    ) {
        sdata_avg_power.resize(self.player.numberOfChannels);
        sdata_peak_power.resize(self.player.numberOfChannels);
    }
    
    sdata_avg_power[channel].AddPoint(t, [self.player averagePowerForChannel:channel]);
    sdata_peak_power[channel].AddPoint(t, [self.player peakPowerForChannel:channel]);
    
    ImGui::SetNextWindowSize(ImVec2(350, 250), ImGuiCond_FirstUseEver);
    
    if (!ImGui::Begin(windowTitles[channel].c_str())) {
        ImGui::End();
        return;
    }
    
    ImGui::PushItemWidth(ImGui::GetFontSize() * -13);
    
    ImGui::LabelText("channel", "%d", channel);
    
    float avg_pwr = [self.player averagePowerForChannel:channel];
    float avg_pwr_sat = 1.0f - avg_pwr / -160.0f;
    ImGui::LabelText("average power [dBFS]", "%f", avg_pwr);
    ImGui::PushStyleColor(ImGuiCol_PlotHistogram, ImVec4(ImColor(84, 113, 171)));
    ImGui::ProgressBar(avg_pwr_sat, ImVec2(0.f, 0.f), "");
    ImGui::PopStyleColor();
    
    float peak_pwr = [self.player peakPowerForChannel:channel];
    float peak_pwr_sat = 1.0f - peak_pwr / -160.0f;
    ImGui::LabelText("peak power [dBFS]", "%f", peak_pwr);
    ImGui::PushStyleColor(ImGuiCol_PlotHistogram, ImVec4(ImColor(209, 136, 92)));
    ImGui::ProgressBar(peak_pwr_sat, ImVec2(0.f, 0.f), "");
    ImGui::PopStyleColor();
    
    char plotId[128];
    ImFormatString(plotId, 128, "##powerPlot%d", channel);
    
    static float history = 5.0f;
    static ImPlotAxisFlags flags = ImPlotAxisFlags_NoTickLabels;
    
    if (ImPlot::BeginPlot(plotId, ImVec2(-1,150))) {
        ImPlot::SetupAxes(nullptr, nullptr, flags, flags);
        ImPlot::SetupAxisLimits(ImAxis_X1, t - history, t, ImGuiCond_Always);
        ImPlot::SetupAxisLimits(ImAxis_Y1, -160, 0);
        ImPlot::SetNextFillStyle(IMPLOT_AUTO_COL, 0.5f);
        
        ImPlot::PlotLine("average power", &sdata_avg_power[channel].Data[0].x, &sdata_avg_power[channel].Data[0].y, sdata_avg_power[channel].Data.size(), 0, sdata_avg_power[channel].Offset, 2 * sizeof(float));
        
        ImPlot::PlotLine("peak power", &sdata_peak_power[channel].Data[0].x, &sdata_peak_power[channel].Data[0].y, sdata_peak_power[channel].Data.size(), 0, sdata_peak_power[channel].Offset, 2 * sizeof(float));
        
        ImPlot::EndPlot();
    }
    
    ImGui::End();
}

@end
