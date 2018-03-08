#include "voro++.hh"
#include <iostream>
#include <iomanip>
using namespace voro;

void progress_bar(float progress) {

  int barWidth = 50;

  std::cout  << " " << std::setfill(' ') << std::setw(3) << int(progress * 100.0) << "%";
  std::cout << " |";
  int pos = barWidth * progress;
  for (int i = 0; i < barWidth; ++i) {
    if (i < pos) std::cout << "=";
    else if (i == pos) std::cout << " "; //">";
    else std::cout << " ";
  }
  std::cout << "| \r";
  std::cout.flush();

  //progress += 0.16; // for demonstration only
  if (progress >= 1.0) std::cout << std::endl;
}


extern "C" {
  void voro_C(int n, int max_neighbours, double limits[6], double x[], double y[], double z[], int icell_start, int icell_end, int cpu_id, int n_cpu, int n_points_per_cpu,
              int &n_in, double volume[], int first_neighbours[], int last_neighbours[], int n_neighbours[], int neighbours_list[], int &ierr) {

    ierr = 0 ;

    // intent(in)
    double ax,bx, ay,by, az, bz ;
    ax = limits[0] ; bx = limits[1] ;
    ay = limits[2] ; by = limits[3] ;
    az = limits[4] ; bz = limits[5] ;

    int i, nx,ny,nz,init_mem(8);

    int row = n_points_per_cpu * max_neighbours ;

    //wall_list wl; // I am not adding extra walls yet
    bool xperiodic,yperiodic,zperiodic ;
    pre_container *pcon=NULL; // pre-container pointer

    xperiodic = false ;
    yperiodic = false ;
    zperiodic = false ;

    // Define a pre-container to determine the optimal block size
    pcon=new pre_container(ax,bx,ay,by,az,bz,xperiodic,yperiodic,zperiodic);
    for(i=0;i<n;i++) {
      //std::cout << i << " " << x[i] << std::endl;
      pcon->put(i,x[i],y[i],z[i]);
    }
    pcon->guess_optimal(nx,ny,nz);

    // define the proper container and point the pre-containet toward it
    particle_order vo;
    container con(ax,bx,ay,by,az,bz,nx,ny,nz,xperiodic,yperiodic,zperiodic,init_mem);

    //con.add_wall(wl);
    pcon->setup(vo,con);
    delete pcon;

    c_loop_order vlo(con,vo);

    // Perform the Voronoi tesselation
    voronoicell_neighbor c(con);
    int pid ;
    std::vector<int> vi;

    int n_neighbours_cell, first_neighbour, last_neighbour ;
    int max_size_list = max_neighbours * n ;

    n_neighbours[cpu_id] = 0 ;
    last_neighbour = -1 ;
    n_in = 0 ;

    float progress = 0.0 ;
    float progress_bar_step = 0.01 ;
    float threshold = progress_bar_step*(1.*n)/n_cpu ;

    if (!vlo.start()) {
      std::cout << "Error : voro++ did not manage to initialize" << std::endl;
      std::cout << "Exiting" << std::endl;
      ierr = 1 ;
      exit(1) ;
    }

    do {
      pid = vlo.pid() ; // id of the current cell in the c_loop

      if ((pid >= icell_start) && (pid <= icell_end)) { // We only compute a fraction of the cells in a given thread
        if (con.compute_cell(c,vlo)) { // return false if the cell was removed
          n_in++ ;

          if (cpu_id == n_cpu-1) {
            if (n_in > threshold) {
              progress  += progress_bar_step ;
              threshold += progress_bar_step*(1.*n)/n_cpu ;
              progress_bar(progress) ;
            }
          }

          // Volume
          volume[pid] = c.volume() ;

          // Store the neighbours list
          n_neighbours_cell = c.number_of_faces() ;
          n_neighbours[cpu_id] = n_neighbours[cpu_id] + n_neighbours_cell ;

          first_neighbour = last_neighbour+1 ; first_neighbours[pid] = first_neighbour ;
          last_neighbour  = last_neighbour + n_neighbours_cell ; last_neighbours[pid]  = last_neighbour ;

          if (n_neighbours[cpu_id] > max_size_list) {
            ierr = 1 ;
            exit(1) ;
          }

          c.neighbors(vi) ;
          for (i=0 ; i<n_neighbours_cell ; i++) {
            //std::cout << "test0 " << row  << " " << n_points_per_cpu << " " << max_neighbours << std::endl;
            if (vi[i] >=0) {
              neighbours_list[row * cpu_id + first_neighbour+i] = vi[i] + 1 ;
            } else {
              // Wall
              neighbours_list[row * cpu_id + first_neighbour+i] = vi[i] ;
            }
          }
        }  // con.compute_cell
      } // pid test

    } while(vlo.inc()); //Finds the next particle to test

    if (cpu_id == n_cpu-1) progress_bar(1.0) ;
  }
}
