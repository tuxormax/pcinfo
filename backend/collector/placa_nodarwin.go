//go:build !darwin

package collector

// placaDarwin y darwinGPUCards solo aplican en macOS (allí no hay DMI y los
// datos salen de system_profiler). Stubs para que compile en el resto.
func placaDarwin(_ *BoardInfo)  {}
func darwinGPUCards() []GPUCard { return []GPUCard{} }
