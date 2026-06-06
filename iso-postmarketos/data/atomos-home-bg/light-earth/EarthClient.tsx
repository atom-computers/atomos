"use client";
import Globe from './Globe';

export default function EarthClient() {
    return (
        <div className="h-screen w-screen bg-white flex items-center justify-center">
            <div className="globe-offset w-screen h-screen">
            <Globe
                baseColor="#fff"
                markerColor="#000"
                glowColor="#ddd"                
                mapSamples={22000}
            />
             </div>
        </div>
    );
}
